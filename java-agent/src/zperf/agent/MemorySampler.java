package zperf.agent;

import java.io.File;
import java.lang.management.BufferPoolMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryPoolMXBean;
import java.lang.management.MemoryType;

/**
 * heap usado/comprometido/max + metaspace + direct/mapped ByteBuffers.
 * Memória nativa do LWJGL (MemoryUtil/malloc) e do driver de vídeo NÃO aparece aqui:
 * compare com o RSS do processo no gerenciador de tarefas para estimar o off-heap total.
 */
final class MemorySampler {
    private MemorySampler() {}

    static AutoCloseable start(File dir, long periodMs) throws Exception {
        Csv csv = new Csv(new File(dir, "memory.csv"),
                "epoch_ms,heap_used_mb,heap_committed_mb,heap_max_mb,metaspace_mb,direct_mb,direct_count,mapped_mb,threads");
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        Daemon d = Daemon.every("zperf-memory", periodMs, () -> {
            var heap = mem.getHeapMemoryUsage();
            long meta = 0;
            for (MemoryPoolMXBean p : ManagementFactory.getMemoryPoolMXBeans()) {
                if (p.getType() == MemoryType.NON_HEAP && p.getName().contains("Metaspace")) {
                    meta += p.getUsage().getUsed();
                }
            }
            long direct = 0, directCount = 0, mapped = 0;
            for (BufferPoolMXBean b : ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class)) {
                if (b.getName().equals("direct")) {
                    direct = b.getMemoryUsed();
                    directCount = b.getCount();
                } else if (b.getName().startsWith("mapped")) {
                    mapped += b.getMemoryUsed();
                }
            }
            csv.row(System.currentTimeMillis(), heap.getUsed() >> 20, heap.getCommitted() >> 20,
                    heap.getMax() >> 20, meta >> 20, direct >> 20, directCount, mapped >> 20,
                    ManagementFactory.getThreadMXBean().getThreadCount());
        });
        return () -> {
            d.close();
            csv.close();
        };
    }
}
