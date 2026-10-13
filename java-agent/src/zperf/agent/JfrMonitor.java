package zperf.agent;

import java.io.File;
import java.time.Duration;
import java.util.List;
import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordedFrame;
import jdk.jfr.consumer.RecordedStackTrace;
import jdk.jfr.consumer.RecordedThread;
import jdk.jfr.consumer.RecordingStream;

/**
 * JFR em streaming dentro do processo (JDK 14+):
 *   jdk.ExecutionSample       -> CPU por thread/subsistema, sem viés de safepoint
 *   jdk.ObjectAllocationSample -> quem aloca (pressão no GC), JDK 16+
 *   jdk.ZAllocationStall      -> thread parada esperando o ZGC liberar memória (o stutter clássico)
 */
final class JfrMonitor {
    private JfrMonitor() {}

    static AutoCloseable start(File dir, Options opt, Hotspots hs) throws Exception {
        Csv stalls = new Csv(new File(dir, "stalls.csv"), "epoch_ms,duration_ms,thread,type,size_mb");
        RecordingStream rs = new RecordingStream();
        rs.setMaxAge(Duration.ofSeconds(10));
        if (opt.sample) {
            rs.enable("jdk.ExecutionSample").withPeriod(Duration.ofMillis(opt.samplePeriodMs));
            rs.onEvent("jdk.ExecutionSample", e -> hs.cpu(threadName(e, "sampledThread"), frames(e)));
            rs.enable("jdk.ObjectAllocationSample").with("throttle", "200/s");
            rs.onEvent("jdk.ObjectAllocationSample", e -> {
                String type = e.getClass("objectClass") == null ? "?" : e.getClass("objectClass").getName();
                hs.alloc(threadName(e, "eventThread"), type, frames(e), e.getLong("weight"));
            });
        }
        rs.enable("jdk.ZAllocationStall").withThreshold(Duration.ofMillis(opt.stallMinMs)).withStackTrace();
        rs.onEvent("jdk.ZAllocationStall", e -> stalls.row(
                e.getStartTime().toEpochMilli(),
                Csv.ms(e.getDuration().toNanos() / 1e6),
                threadName(e, "eventThread"),
                e.hasField("type") ? e.getValue("type") : "",
                e.hasField("size") ? (e.getLong("size") >> 20) : ""));
        // startAsync() cria thread NÃO-daemon e impede a JVM de encerrar; rodamos start() numa daemon.
        Thread t = new Thread(() -> {
            try {
                rs.start();
            } catch (Throwable e) {
                ZPerfAgent.log("jfr stream: " + e);
            }
        }, "zperf-jfr");
        t.setDaemon(true);
        t.start();
        return () -> {
            rs.close();
            stalls.close();
        };
    }

    private static String threadName(RecordedEvent e, String field) {
        RecordedThread t = e.hasField(field) ? e.getThread(field) : e.getThread();
        if (t == null) return "?";
        String n = t.getJavaName();
        return n != null ? n : t.getOSName();
    }

    private static final String[] EMPTY = new String[0];

    static String[] frames(RecordedEvent e) {
        RecordedStackTrace st = e.getStackTrace();
        if (st == null) return EMPTY;
        List<RecordedFrame> fs = st.getFrames();
        int n = Math.min(fs.size(), 64);
        String[] out = new String[n];
        for (int i = 0; i < n; i++) {
            RecordedFrame f = fs.get(i);
            out[i] = f.getMethod().getType().getName() + "." + f.getMethod().getName();
        }
        return out;
    }
}
