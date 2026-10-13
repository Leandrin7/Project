package se.krka.kahlua.vm;

public class KahluaThread {
    public Coroutine currentCoroutine = new Coroutine();

    /** Simula Lua "trabalhando": empilha handler + folha e gira CPU alocando lixo. */
    public long run(LuaClosure handler, LuaClosure leaf, long nanos) {
        currentCoroutine.push(handler, 1);
        currentCoroutine.push(leaf, 2);
        long end = System.nanoTime() + nanos;
        long acc = 0;
        while (System.nanoTime() < end) {
            Double d = Double.valueOf(acc * 0.5); // boxing como o Kahlua faz
            acc += d.hashCode() & 7;
            Object[] garbage = new Object[16];
            acc += garbage.length;
        }
        currentCoroutine.pop();
        currentCoroutine.pop();
        return acc;
    }
}
