package zperf.agent;

import com.sun.management.GarbageCollectionNotificationInfo;
import com.sun.management.GcInfo;
import java.io.File;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import javax.management.Notification;
import javax.management.NotificationEmitter;
import javax.management.NotificationListener;
import javax.management.openmbean.CompositeData;

/**
 * Uma linha por coleta. Coluna "kind":
 *   pause      = stop-the-world (todas as threads do jogo param) -> causa stutter direto
 *   concurrent = ciclo concorrente (ZGC/Shenandoah "Cycles", G1 "Concurrent GC") -> rouba CPU
 */
final class GcMonitor implements AutoCloseable {
    private final Csv csv;
    private final List<Runnable> unregister = new ArrayList<>();

    private GcMonitor(File dir) throws Exception {
        csv = new Csv(new File(dir, "gc.csv"),
                "epoch_ms,uptime_ms,collector,kind,action,cause,duration_ms,heap_before_mb,heap_after_mb");
        long uptimeBase = ManagementFactory.getRuntimeMXBean().getStartTime();
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (!(gc instanceof NotificationEmitter)) continue;
            NotificationEmitter em = (NotificationEmitter) gc;
            NotificationListener l = (Notification n, Object hb) -> onNotification(n, uptimeBase);
            em.addNotificationListener(l, null, null);
            unregister.add(() -> {
                try {
                    em.removeNotificationListener(l);
                } catch (Exception ignored) {
                    // já removido
                }
            });
        }
    }

    static GcMonitor start(File dir) throws Exception {
        return new GcMonitor(dir);
    }

    static String kindOf(String collector, String action) {
        String c = collector.toLowerCase();
        if (c.contains("cycles") || c.contains("concurrent")) return "concurrent";
        return "pause";
    }

    private void onNotification(Notification n, long startEpoch) {
        if (!GarbageCollectionNotificationInfo.GARBAGE_COLLECTION_NOTIFICATION.equals(n.getType())) return;
        GarbageCollectionNotificationInfo info =
                GarbageCollectionNotificationInfo.from((CompositeData) n.getUserData());
        GcInfo gi = info.getGcInfo();
        csv.row(startEpoch + gi.getStartTime(), gi.getStartTime(), info.getGcName(),
                kindOf(info.getGcName(), info.getGcAction()), info.getGcAction(), info.getGcCause(),
                gi.getDuration(), mb(sum(gi.getMemoryUsageBeforeGc())), mb(sum(gi.getMemoryUsageAfterGc())));
    }

    private static long sum(Map<String, MemoryUsage> m) {
        long s = 0;
        for (Map.Entry<String, MemoryUsage> e : m.entrySet()) {
            String k = e.getKey().toLowerCase();
            // só pools do heap Java
            if (k.contains("metaspace") || k.contains("code") || k.contains("compressed class")) continue;
            s += e.getValue().getUsed();
        }
        return s;
    }

    static long mb(long bytes) {
        return bytes >> 20;
    }

    @Override
    public void close() throws java.io.IOException {
        unregister.forEach(Runnable::run);
        csv.close();
    }
}
