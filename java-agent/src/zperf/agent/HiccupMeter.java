package zperf.agent;

import java.io.File;
import java.util.concurrent.locks.LockSupport;

/**
 * Medidor de "hiccups" estilo jHiccup: uma thread pede para dormir 1 ms e mede quanto
 * realmente dormiu. Se ela atrasou 80 ms, TODA a JVM (ou o SO) parou 80 ms:
 * pausa de GC, safepoint, page fault em massa, swap, antivírus...
 *
 * Interpretação:
 *   stutter no jogo + hiccup no mesmo instante  -> JVM/SO (GC, safepoint, memória)
 *   stutter no jogo SEM hiccup                  -> trabalho na thread do jogo (Lua, render, IA)
 *
 * No Windows sem timer de 1 ms o piso é ~15,6 ms; use hiccupMs >= 20.
 */
final class HiccupMeter {
    private static final long[] BUCKETS_MS = {1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, Long.MAX_VALUE};

    private HiccupMeter() {}

    static AutoCloseable start(File dir, long thresholdMs) throws Exception {
        Csv csv = new Csv(new File(dir, "hiccups.csv"), "epoch_ms,hiccup_ms");
        Csv hist = new Csv(new File(dir, "hiccup-histogram.csv"), "epoch_ms,bucket_le_ms,count");
        long[] counts = new long[BUCKETS_MS.length];
        long thresholdNs = thresholdMs * 1_000_000L;
        Thread t = new Thread(() -> {
            long lastHist = System.nanoTime();
            while (!Thread.currentThread().isInterrupted()) {
                long t0 = System.nanoTime();
                LockSupport.parkNanos(1_000_000L);
                long over = System.nanoTime() - t0 - 1_000_000L;
                long overMs = over / 1_000_000L;
                for (int i = 0; i < BUCKETS_MS.length; i++) {
                    if (overMs <= BUCKETS_MS[i]) {
                        counts[i]++;
                        break;
                    }
                }
                if (over >= thresholdNs) {
                    csv.row(System.currentTimeMillis(), Csv.ms(over / 1e6));
                }
                if (t0 - lastHist > 60_000_000_000L) {
                    lastHist = t0;
                    long now = System.currentTimeMillis();
                    for (int i = 0; i < BUCKETS_MS.length; i++) {
                        hist.row(now, BUCKETS_MS[i] == Long.MAX_VALUE ? "inf" : BUCKETS_MS[i], counts[i]);
                        counts[i] = 0;
                    }
                }
            }
        }, "zperf-hiccup");
        t.setDaemon(true);
        t.setPriority(Thread.MAX_PRIORITY);
        t.start();
        return () -> {
            t.interrupt();
            long now = System.currentTimeMillis();
            for (int i = 0; i < BUCKETS_MS.length; i++) {
                hist.row(now, BUCKETS_MS[i] == Long.MAX_VALUE ? "inf" : BUCKETS_MS[i], counts[i]);
            }
            csv.close();
            hist.close();
        };
    }
}
