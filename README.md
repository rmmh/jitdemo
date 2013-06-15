jitdemo-2
=========

An optimizing Brainfuck JIT interpreter, based on [Josh Haberman's naive BF JIT](http://blog.reverberate.org/2012/12/hello-jit-world-joy-of-simple-jits.html).

Uses flex to find patterns to optimize, and DynASM to emit x86 code.

On mandelbrot.bf, jit4 (optimizing JIT) is ~3.8x faster than jit3 (naive JIT).
