package zperf.agent;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.LongAdder;

/** Agrega amostras (CPU Java, alocação, pilha Lua) e grava top-N em hotspots.txt. */
final class Hotspots implements AutoCloseable {
    /** Prefixo de classe -> subsistema. Primeiro match a partir do frame folha vence. */
    private static final String[][] CATEGORIES = {
        {"se.krka.kahlua", "lua"},
        {"zombie.Lua", "lua-bridge"},
        {"zombie.core.skinnedmodel", "animation"},
        {"zombie.core.physics", "physics"},
        {"zombie.pathfind", "pathfinding"},
        {"zombie.vehicles.PolygonalMap2", "pathfinding"},
        {"zombie.ai", "ai"},
        {"zombie.behaviors", "ai"},
        {"zombie.popman", "population"},
        {"zombie.characters", "characters"},
        {"zombie.iso.LightingJNI", "lighting"},
        {"zombie.iso.IsoCell", "world-render/update"},
        {"zombie.iso", "world"},
        {"zombie.core.opengl", "render"},
        {"zombie.core.textures", "render"},
        {"zombie.core.sprite", "render"},
        {"org.lwjgl", "render-gl"},
        {"zombie.network", "network"},
        {"zombie.audio", "audio"},
        {"fmod", "audio"},
        {"zombie.worldMap", "worldmap"},
        {"zombie.savefile", "io"},
        {"java.io", "io"},
        {"java.nio", "io"},
        {"java.util.zip", "io"},
    };

    private final File file;
    private final int topN;
    private final Map<String, LongAdder> cpuCategory = new ConcurrentHashMap<>();
    private final Map<String, LongAdder> cpuFrames = new ConcurrentHashMap<>();
    private final Map<String, LongAdder> allocCategory = new ConcurrentHashMap<>();
    private final Map<String, LongAdder> allocFrames = new ConcurrentHashMap<>();
    private final Map<String, LongAdder> luaRoot = new ConcurrentHashMap<>();
    private final Map<String, LongAdder> luaLeaf = new ConcurrentHashMap<>();
    private final LongAdder luaSamples = new LongAdder();
    private final LongAdder luaIdle = new LongAdder();

    Hotspots(File dir, int topN) {
        this.file = new File(dir, "hotspots.txt");
        this.topN = topN;
    }

    static String category(String[] frames) {
        for (String f : frames) {
            if (f.startsWith("se.krka.kahlua")) return "lua (inclui API Java chamada pelo Lua)";
        }
        for (String f : frames) {
            for (String[] c : CATEGORIES) {
                if (f.startsWith(c[0])) return c[1];
            }
        }
        return "other";
    }

    /** Threads do próprio agente e do JFR não entram no relatório. */
    static boolean isOwn(String thread) {
        return thread.startsWith("zperf-") || thread.startsWith("JFR ");
    }

    private static void add(Map<String, LongAdder> m, String k, long v) {
        m.computeIfAbsent(k, x -> new LongAdder()).add(v);
    }

    /** frames: folha primeiro, "pacote.Classe.metodo". */
    void cpu(String thread, String[] frames) {
        if (frames.length == 0 || isOwn(thread)) return;
        add(cpuCategory, thread + " :: " + category(frames), 1);
        add(cpuFrames, thread + " :: " + frames[0], 1);
    }

    void alloc(String thread, String type, String[] frames, long weight) {
        if (isOwn(thread)) return;
        String cat = frames.length == 0 ? "other" : category(frames);
        add(allocCategory, thread + " :: " + cat, weight);
        String site = frames.length == 0 ? "?" : firstGameFrame(frames);
        add(allocFrames, type + " @ " + site, weight);
    }

    /** Primeiro frame fora do JDK: quem realmente pediu a alocação. */
    static String firstGameFrame(String[] frames) {
        for (String f : frames) {
            if (!f.startsWith("java.") && !f.startsWith("jdk.") && !f.startsWith("sun.")) return f;
        }
        return frames[0];
    }

    void lua(String root, String leaf) {
        luaSamples.increment();
        add(luaRoot, root, 1);
        add(luaLeaf, leaf, 1);
    }

    void luaIdle() {
        luaIdle.increment();
    }

    synchronized void flush() {
        try (PrintWriter out = new PrintWriter(new FileWriter(file, true))) {
            out.println("==== " + new SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date()) + " ====");
            section(out, "CPU por thread :: subsistema (amostras)", cpuCategory, "");
            section(out, "CPU frame folha (amostras)", cpuFrames, "");
            section(out, "Alocação por thread :: subsistema (bytes estimados)", allocCategory, "B");
            section(out, "Alocação por tipo @ site (bytes estimados)", allocFrames, "B");
            long in = luaSamples.sumThenReset();
            long idle = luaIdle.sumThenReset();
            if (in + idle > 0) {
                out.printf("-- Lua ativo em %.1f%% das amostras (%d/%d)%n", 100.0 * in / (in + idle), in, in + idle);
            }
            section(out, "Lua: handler raiz (quem o evento chamou)", luaRoot, "");
            section(out, "Lua: função folha (onde o tempo está)", luaLeaf, "");
            out.println();
        } catch (IOException e) {
            ZPerfAgent.log("hotspots: " + e);
        }
    }

    private void section(PrintWriter out, String title, Map<String, LongAdder> m, String unit) {
        if (m.isEmpty()) return;
        List<Map.Entry<String, Long>> list = new ArrayList<>();
        long total = 0;
        for (Map.Entry<String, LongAdder> e : m.entrySet()) {
            long v = e.getValue().sumThenReset();
            if (v == 0) continue;
            total += v;
            list.add(Map.entry(e.getKey(), v));
        }
        m.clear();
        if (list.isEmpty()) return;
        list.sort((a, b) -> Long.compare(b.getValue(), a.getValue()));
        out.println("-- " + title + " total=" + human(total, unit));
        for (int i = 0; i < Math.min(topN, list.size()); i++) {
            Map.Entry<String, Long> e = list.get(i);
            out.printf("%5.1f%%  %10s  %s%n", 100.0 * e.getValue() / total, human(e.getValue(), unit), e.getKey());
        }
    }

    static String human(long v, String unit) {
        if (!"B".equals(unit)) return Long.toString(v);
        if (v >= 1L << 30) return String.format("%.1fGB", v / (double) (1L << 30));
        if (v >= 1L << 20) return String.format("%.1fMB", v / (double) (1L << 20));
        if (v >= 1L << 10) return String.format("%.1fKB", v / (double) (1L << 10));
        return v + "B";
    }

    @Override
    public void close() {
        flush();
    }
}
