package zperf.agent;

import java.lang.instrument.Instrumentation;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.List;

/**
 * Amostra a pilha Lua do Kahlua por reflexão (leitura racy, sem locks, só observação).
 *
 * Layout esperado (Kahlua2 upstream; o fork do PZ pode diferir — confirme com REA):
 *   zombie.Lua.LuaManager.thread            : se.krka.kahlua.vm.KahluaThread (static)
 *   KahluaThread.currentCoroutine           : Coroutine
 *   Coroutine.callFrameStack / callFrameTop : LuaCallFrame[] / int
 *   LuaCallFrame.closure / pc               : LuaClosure / int
 *   LuaClosure.prototype                    : Prototype
 *   Prototype.filename|file|name / lines    : String / int[]
 *
 * Se algum campo não existir, o sampler se desliga e imprime os campos reais da classe
 * para você ajustar (ou rodar o playbook REA e corrigir os nomes aqui).
 */
final class LuaSampler {
    private final Options opt;
    private final Instrumentation inst;
    private final Hotspots hs;
    private Field threadF, coroutineF, stackF, topF, closureF, pcF, protoF, nameF, linesF;

    private LuaSampler(Options opt, Instrumentation inst, Hotspots hs) {
        this.opt = opt;
        this.inst = inst;
        this.hs = hs;
    }

    static AutoCloseable start(Options opt, Instrumentation inst, Hotspots hs) {
        LuaSampler s = new LuaSampler(opt, inst, hs);
        Thread t = new Thread(s::loop, "zperf-lua");
        t.setDaemon(true);
        t.start();
        return t::interrupt;
    }

    private void loop() {
        try {
            if (!awaitBound()) return;
            long periodNs = 1_000_000_000L / Math.max(1, opt.luaHz);
            java.util.concurrent.ThreadLocalRandom rnd = java.util.concurrent.ThreadLocalRandom.current();
            while (!Thread.currentThread().isInterrupted()) {
                sample();
                // jitter de ±50%: evita aliasing com o ritmo fixo dos frames do jogo
                java.util.concurrent.locks.LockSupport.parkNanos(periodNs / 2 + rnd.nextLong(periodNs));
            }
        } catch (Throwable t) {
            ZPerfAgent.log("lua sampler parou: " + t);
        }
    }

    /** Espera o jogo carregar e inicializar LuaManager (nunca forçamos a inicialização). */
    private boolean awaitBound() throws InterruptedException {
        Class<?> lm = null;
        while (lm == null) {
            Thread.sleep(2000);
            lm = findLoaded(opt.luaManagerClass);
        }
        Thread.sleep(5000); // margem para o <clinit> terminar na thread do jogo
        try {
            threadF = field(lm, opt.luaThreadField);
            if (!Modifier.isStatic(threadF.getModifiers())) throw new NoSuchFieldException(opt.luaThreadField + " não é static");
            Object kt;
            while ((kt = threadF.get(null)) == null) Thread.sleep(2000);
            coroutineF = field(kt.getClass(), "currentCoroutine");
            Class<?> co = coroutineF.getType();
            stackF = field(co, "callFrameStack");
            topF = field(co, "callFrameTop");
            Class<?> frame = stackF.getType().getComponentType();
            closureF = field(frame, "closure");
            pcF = field(frame, "pc");
            protoF = field(closureF.getType(), "prototype");
            Class<?> proto = protoF.getType();
            nameF = firstField(proto, "filename", "file", "name");
            linesF = field(proto, "lines");
            ZPerfAgent.log("lua sampler ligado em " + kt.getClass().getName());
            return true;
        } catch (NoSuchFieldException | IllegalAccessException e) {
            ZPerfAgent.log("lua sampler: layout do Kahlua diferente do esperado: " + e.getMessage());
            return false;
        }
    }

    private Class<?> findLoaded(String name) {
        if (inst != null) {
            for (Class<?> c : inst.getAllLoadedClasses()) {
                if (c.getName().equals(name)) return c;
            }
            return null;
        }
        try {
            return Class.forName(name, false, ClassLoader.getSystemClassLoader());
        } catch (ClassNotFoundException e) {
            return null;
        }
    }

    private void sample() {
        try {
            Object kt = threadF.get(null);
            Object co = kt == null ? null : coroutineF.get(kt);
            if (co == null) {
                hs.luaIdle();
                return;
            }
            int top = topF.getInt(co);
            Object[] stack = (Object[]) stackF.get(co);
            if (top <= 0 || stack == null || top > stack.length) {
                hs.luaIdle();
                return;
            }
            hs.lua(frameName(stack[0]), frameName(stack[top - 1]));
        } catch (Throwable t) {
            // corrida com a thread do jogo: descarta a amostra
        }
    }

    private String frameName(Object frame) throws IllegalAccessException {
        if (frame == null) return "?";
        Object closure = closureF.get(frame);
        if (closure == null) return "[java]";
        Object proto = protoF.get(closure);
        if (proto == null) return "?";
        Object name = nameF.get(proto);
        int[] lines = (int[]) linesF.get(proto);
        int pc = pcF.getInt(frame);
        int line = (lines != null && pc > 0 && pc <= lines.length) ? lines[pc - 1] : -1;
        return name + ":" + line;
    }

    static Field field(Class<?> c, String name) throws NoSuchFieldException {
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try {
                Field f = k.getDeclaredField(name);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
                // sobe na hierarquia
            }
        }
        throw new NoSuchFieldException(c.getName() + "." + name + " (campos: " + describe(c) + ")");
    }

    static Field firstField(Class<?> c, String... names) throws NoSuchFieldException {
        for (String n : names) {
            try {
                Field f = field(c, n);
                if (f.getType() == String.class) return f;
            } catch (NoSuchFieldException ignored) {
                // tenta o próximo
            }
        }
        throw new NoSuchFieldException(c.getName() + ".{" + String.join("|", names) + "} (campos: " + describe(c) + ")");
    }

    static String describe(Class<?> c) {
        List<String> out = new ArrayList<>();
        for (Field f : c.getDeclaredFields()) out.add(f.getType().getSimpleName() + " " + f.getName());
        return String.join(", ", out);
    }
}
