
CFLAGS=-O3 -g -std=gnu99

all: jit1 jit2 jit3 jit4

jit1: jit1.c

jit2: dynasm-driver.c jit2.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o jit2 dynasm-driver.c -DJIT=\"jit2.h\"
jit3: dynasm-driver.c jit3.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o jit3 dynasm-driver.c -DJIT=\"jit3.h\"
jit4: dynasm-driver.c jit4.h
	$(CC) -m32 $(CFLAGS) $(CPPFLAGS) -o jit4 dynasm-driver.c -DJIT=\"jit4.h\"

jit4.dasc: jit4.dasc.l
	flex -bt jit4.dasc.l > jit4.dasc

%.h: %.dasc
	lua dynasm/dynasm.lua $< > $@

clean:
	rm -f jit1 jit2 jit3 jit4 jit1.h jit2.h jit3.h jit4.h
