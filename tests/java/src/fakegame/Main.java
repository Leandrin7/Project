package fakegame;

import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaClosure;
import se.krka.kahlua.vm.Prototype;
import zombie.Lua.LuaManager;

/** "Jogo" de teste: 70% do tempo em Lua (ModHeavy), 10% em ModLight, resto ocioso. */
public class Main {
    public static void main(String[] args) throws Exception {
        long seconds = Long.parseLong(args[0]);
        LuaManager.thread = new KahluaThread();
        LuaClosure heavy = new LuaClosure(new Prototype("media/lua/client/ModHeavy.lua", new int[] {10, 42}));
        LuaClosure light = new LuaClosure(new Prototype("media/lua/client/ModLight.lua", new int[] {5, 7}));
        LuaClosure helper = new LuaClosure(new Prototype("media/lua/shared/Util.lua", new int[] {99, 100}));
        long end = System.currentTimeMillis() + seconds * 1000;
        long sink = 0;
        while (System.currentTimeMillis() < end) {
            sink += LuaManager.thread.run(heavy, helper, 7_000_000L);
            sink += LuaManager.thread.run(light, helper, 1_000_000L);
            Thread.sleep(2);
        }
        System.out.println("done " + (sink & 1));
    }
}
