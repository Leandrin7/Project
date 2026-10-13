package zperf.agent;

/** Thread daemon periódica com prioridade baixa; nunca concorre com o loop do jogo. */
final class Daemon implements AutoCloseable {
    private final Thread thread;
    private volatile boolean running = true;

    private Daemon(String name, long periodMs, Runnable task, int priority) {
        thread = new Thread(() -> {
            while (running) {
                try {
                    Thread.sleep(periodMs);
                    task.run();
                } catch (InterruptedException e) {
                    return;
                } catch (Throwable t) {
                    ZPerfAgent.log(name + ": " + t);
                }
            }
        }, name);
        thread.setDaemon(true);
        thread.setPriority(priority);
        thread.start();
    }

    static Daemon every(String name, long periodMs, Runnable task) {
        return new Daemon(name, periodMs, task, Thread.MIN_PRIORITY);
    }

    @Override
    public void close() {
        running = false;
        thread.interrupt();
    }
}
