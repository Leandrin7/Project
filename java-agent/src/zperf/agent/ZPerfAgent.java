package zperf.agent;

import java.io.File;
import java.lang.instrument.Instrumentation;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

/**
 * Agente de diagnóstico para o Project Zomboid (sem dependências, JDK 17+).
 *
 * <pre>
 * -javaagent:zperf-agent.jar=hiccupMs=20,sample=true,lua=true,reportSec=30
 * </pre>
 *
 * Saída em ~/Zomboid/zperf/&lt;timestamp&gt;/:
 *   gc.csv        cada coleta (pausa vs ciclo concorrente), heap antes/depois
 *   stalls.csv    ZGC Allocation Stall (thread do jogo parada esperando o GC) via JFR
 *   hiccups.csv   pausas da JVM/SO vistas por uma thread que dorme 1 ms
 *   memory.csv    heap, metaspace, direct/mapped buffers a cada segundo
 *   hotspots.txt  top frames Java por thread (JFR ExecutionSample) e top funções Lua
 *
 * Nada aqui modifica bytecode do jogo: é observação pura, seguro para usar com qualquer mod.
 */
public final class ZPerfAgent {
    private static volatile boolean started;
    private static final List<AutoCloseable> closeables = new ArrayList<>();

    private ZPerfAgent() {}

    public static void premain(String args, Instrumentation inst) {
        start(args, inst);
    }

    public static void agentmain(String args, Instrumentation inst) {
        start(args, inst);
    }

    public static synchronized void start(String args, Instrumentation inst) {
        if (started) return;
        started = true;
        Options opt = Options.parse(args);
        File dir = new File(opt.out, new SimpleDateFormat("yyyyMMdd-HHmmss").format(new Date()));
        if (!dir.mkdirs() && !dir.isDirectory()) {
            System.err.println("[ZPerf] não foi possível criar " + dir);
            return;
        }
        log("saida: " + dir.getAbsolutePath() + " opts=" + opt);

        tryStart("gc", () -> closeables.add(GcMonitor.start(dir)));
        tryStart("memory", () -> closeables.add(MemorySampler.start(dir, opt.memoryMs)));
        tryStart("hiccup", () -> closeables.add(HiccupMeter.start(dir, opt.hiccupMs)));
        Hotspots hotspots = new Hotspots(dir, opt.topN);
        closeables.add(hotspots);
        tryStart("jfr", () -> closeables.add(JfrMonitor.start(dir, opt, hotspots)));
        if (opt.lua) {
            tryStart("lua", () -> closeables.add(LuaSampler.start(opt, inst, hotspots)));
        }
        closeables.add(Daemon.every("zperf-report", opt.reportSec * 1000L, hotspots::flush));

        Runtime.getRuntime().addShutdownHook(new Thread(ZPerfAgent::stop, "zperf-shutdown"));
    }

    static void stop() {
        for (int i = closeables.size() - 1; i >= 0; i--) {
            try {
                closeables.get(i).close();
            } catch (Throwable t) {
                // shutdown: melhor esforço
            }
        }
    }

    interface Starter {
        void run() throws Throwable;
    }

    /** Módulos ausentes num JRE enxuto (jdk.jfr, jdk.management) desligam só a parte afetada. */
    private static void tryStart(String name, Starter s) {
        try {
            s.run();
            log(name + " ativo");
        } catch (Throwable t) {
            log(name + " desativado: " + t);
        }
    }

    static void log(String msg) {
        System.out.println("[ZPerf] " + msg);
    }
}
