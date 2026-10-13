package zperf.agent;

import java.io.File;

/** Argumentos do agente: chave=valor separados por vírgula. */
final class Options {
    File out = new File(System.getProperty("user.home"), "Zomboid" + File.separator + "zperf");
    long hiccupMs = 20;
    long memoryMs = 1000;
    boolean sample = true;          // JFR ExecutionSample (sem safepoint bias)
    int samplePeriodMs = 10;
    boolean lua = true;             // amostragem da pilha Lua (Kahlua) via reflexão
    int luaHz = 100;
    int reportSec = 30;
    int topN = 25;
    long stallMinMs = 1;            // menor ZAllocationStall registrado
    // Layout do Kahlua do PZ. Confirme com o playbook REA (docs/05-rea-playbook.md).
    String luaManagerClass = "zombie.Lua.LuaManager";
    String luaThreadField = "thread";

    static Options parse(String args) {
        Options o = new Options();
        if (args == null || args.isBlank()) return o;
        for (String kv : args.split(",")) {
            int eq = kv.indexOf('=');
            if (eq <= 0) continue;
            String k = kv.substring(0, eq).trim();
            String v = kv.substring(eq + 1).trim();
            switch (k) {
                case "out": o.out = new File(v); break;
                case "hiccupMs": o.hiccupMs = Long.parseLong(v); break;
                case "memoryMs": o.memoryMs = Long.parseLong(v); break;
                case "sample": o.sample = Boolean.parseBoolean(v); break;
                case "samplePeriodMs": o.samplePeriodMs = Integer.parseInt(v); break;
                case "lua": o.lua = Boolean.parseBoolean(v); break;
                case "luaHz": o.luaHz = Integer.parseInt(v); break;
                case "reportSec": o.reportSec = Integer.parseInt(v); break;
                case "topN": o.topN = Integer.parseInt(v); break;
                case "stallMinMs": o.stallMinMs = Long.parseLong(v); break;
                case "luaManagerClass": o.luaManagerClass = v; break;
                case "luaThreadField": o.luaThreadField = v; break;
                default: ZPerfAgent.log("opção desconhecida: " + k);
            }
        }
        return o;
    }

    @Override
    public String toString() {
        return "hiccupMs=" + hiccupMs + " sample=" + sample + "/" + samplePeriodMs + "ms lua=" + lua + "/" + luaHz
                + "Hz reportSec=" + reportSec;
    }
}
