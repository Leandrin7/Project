package se.krka.kahlua.vm;

public class Coroutine {
    private LuaCallFrame[] callFrameStack = new LuaCallFrame[8];
    private int callFrameTop;

    public Coroutine() {
        for (int i = 0; i < callFrameStack.length; i++) callFrameStack[i] = new LuaCallFrame();
    }

    public void push(LuaClosure c, int pc) {
        LuaCallFrame f = callFrameStack[callFrameTop++];
        f.closure = c;
        f.pc = pc;
    }

    public void pop() {
        callFrameTop--;
    }
}
