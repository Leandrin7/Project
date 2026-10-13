package zperf.agent;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

/** CSV append-only, thread-safe, com flush periódico para sobreviver a crash do jogo. */
final class Csv implements AutoCloseable {
    private final BufferedWriter w;
    private long lastFlush = System.nanoTime();

    Csv(File file, String header) throws IOException {
        w = new BufferedWriter(new FileWriter(file, false), 1 << 16);
        w.write(header);
        w.newLine();
        w.flush();
    }

    synchronized void row(Object... cols) {
        try {
            for (int i = 0; i < cols.length; i++) {
                if (i > 0) w.write(',');
                String s = String.valueOf(cols[i]);
                if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0) {
                    s = '"' + s.replace("\"", "\"\"") + '"';
                }
                w.write(s);
            }
            w.newLine();
            long now = System.nanoTime();
            if (now - lastFlush > 2_000_000_000L) {
                w.flush();
                lastFlush = now;
            }
        } catch (IOException e) {
            // disco cheio etc.: não derruba o jogo
        }
    }

    @Override
    public synchronized void close() throws IOException {
        w.close();
    }

    static String ms(double v) {
        return String.format(java.util.Locale.ROOT, "%.3f", v);
    }
}
