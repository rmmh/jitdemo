%top{
// JIT for Brainf*ck.

#include <stdint.h>
#include <sys/stat.h>

|.arch x86
|.actionlist actions
|
|// Use ebx as our cell pointer.
|// Since ebx is a callee-save register, it will be preserved
|// across our calls to getchar and putchar.
|.define PTR, ebx
|
|// ~10% smaller assembly when zero is in a register
|.define ZERO, cl
|
|// Macro for calling a function.
|// restores our zero register after
|.macro callp, addr
| call   &addr
| mov    ZERO, 0
|.endmacro

#define Dst &state
#define MAX_NESTING 256

#define MAX_SHIFT_DIST 128
#define SHIFT_BUFSIZE (MAX_SHIFT_DIST * 2 + 1)

// store a basic block (anything without branches) results
// digest [-+><]* into the updates involved
struct bb_effect_t {
  int ptr_offset;
  int8_t diff[SHIFT_BUFSIZE]; // diff[MAX_SHIFT_DIST] is how much ptr[0] changes
} bb_effect;

// update bb_effect
// returns number of offsets changed, or -1 on error
int compute_bb_effect(char *buf, int len) {
  // count the values added to different offsets
  // we assume changed values are within MAX_SHIFT_DIST bytes
  // of ptr, and abort otherwise
  memset(&bb_effect, 0, sizeof(bb_effect));

  int off = MAX_SHIFT_DIST;

  for (int i = 0; i < len; ++i) {
    switch(buf[i]) {
      case '+': bb_effect.diff[off]++; break;
      case '-': bb_effect.diff[off]--; break;
      case '<': if (--off < 0) return -1; break;
      case '>': if (++off >= SHIFT_BUFSIZE) return -1; break;
    }
  }

  bb_effect.ptr_offset = off - 128;

  int touched = 0;
  for (int i = 0; i < SHIFT_BUFSIZE; ++i) {
    if (bb_effect.diff[i]) {
      touched++;
    }
  }
  return touched;
}

dasm_State *state;
unsigned int maxpc = 0;
int pcstack[MAX_NESTING];
int *top = pcstack, *limit = pcstack + MAX_NESTING;

int addcount(char *buf, int len) {
  int ret = 0;
  for (int i = 0; i < len; i++) {
    if (buf[i] == '+') {
      ret++;
    } else if (buf[i] == '-') {
      ret--;
    }
  }
  return ret;
}

int shiftcount(char *buf, int len) {
  int ret = 0;
  for (int i = 0; i < len; i++) {
    if (buf[i] == '>') {
      ret++;
    } else if ( buf[i] == '<') {
      ret--;
    }
  }
  return ret;
}

void err(const char *msg) {
  fprintf(stderr, "%s\n", msg);
  exit(1);
}

void emit_arith(int diff, int offset) {
  if (diff == 1) {
    | inc byte [PTR+offset]
  } else if (diff == -1) {
    | dec byte [PTR+offset]
  } else if (diff > 0) {
    | add byte [PTR+offset], diff
  } else if (diff < 0) {
    | sub byte [PTR+offset], -diff
  }
}

void emit_shift(int count) {
  if (count == 1) {
    | inc PTR
  } else if (count == -1) {
    | dec PTR
  } else if (count > 0) {
    | add PTR, count
  } else if (count < 0) {
    | sub PTR, -count
  }
}

}
%%

"."   {
  |  mov al, byte [PTR]
  |  push eax
  |  callp putchar
  |  pop eax
}
","   {
  |  callp getchar
  |  mov   byte [PTR], al
}
"["   {
  if (top == limit) err("Nesting too deep.");
  // Each loop gets two pclabels: at the beginning and end.
  // We store pclabel offsets in a stack to link the loop
  // begin and end together.
  maxpc += 2;
  *top++ = maxpc;
  dasm_growpc(&state, maxpc);
  |  cmp  byte [PTR], ZERO
  |  je   =>(maxpc-2)
  |=>(maxpc-1):
}
"]"   {
  if (top == pcstack) err("Unmatched ']'");
  top--;
  |  cmp  byte [PTR], ZERO
  |  jne  =>(*top-1)
  |=>(*top-2):
}
[<>]+   {
  int count = shiftcount(yytext, yyleng);
  emit_shift(count);
}
[-+]+   {
  int count = addcount(yytext, yyleng);
  emit_arith(count, 0);
}
"["[-+><]*"]"[-+]* {
  // optimize loops with zero net pointer offset
  // that decrement ptr[0] once
  // i.e., add/sub loops [->>>+<<<]
  // also handles [-] -> ptr[0] and [-]+ -> ptr[0] = 1, etc

  // check for trailing +-
  int rb_pos = strchr(yytext, ']') - yytext;
  int post_diff = addcount(yytext + rb_pos, yyleng - rb_pos);

  int num_touched = compute_bb_effect(yytext, rb_pos);

  if (num_touched == -1) {
    REJECT;
  }
  // zero net ptr offset
  if (bb_effect.ptr_offset != 0) {
    REJECT;
  }
  // ptr[0] decremented once
  if (bb_effect.diff[MAX_SHIFT_DIST] != -1) {
    REJECT;
  }
  // only handle a single inc/dec per loc per loop
  for (int i = 0; i < SHIFT_BUFSIZE; ++i) {
    if (bb_effect.diff[i] < -1 || bb_effect.diff[i] > 1) {
      REJECT;
    }
  }

  if (num_touched > 1) { // num_touched == 1 implies [-]
    | mov   al, byte [PTR]
  }

  for (int i = 0; i < SHIFT_BUFSIZE; ++i) {
    if (i == MAX_SHIFT_DIST) {
      assert(bb_effect.diff[i] == -1);
      if (post_diff == 0) {
        | mov byte [PTR], ZERO
      } else {
        | mov byte [PTR], post_diff
      }
    } else if (bb_effect.diff[i] == 1) {
      | add byte [PTR+i-MAX_SHIFT_DIST], al
    } else if (bb_effect.diff[i] == -1) {
      | sub byte [PTR+i-MAX_SHIFT_DIST], al
    }
  }
}
[-+><]+ {
  // optimize "basic blocks"
  if (compute_bb_effect(yytext, yyleng) == -1) {
    REJECT;
  }

  int preshift = 0;
  if (!bb_effect.diff[MAX_SHIFT_DIST]) {
    // ptr[0] isn't modified, shift first
    emit_shift(bb_effect.ptr_offset);
    preshift = bb_effect.ptr_offset;
  }

  for (int i = 0; i < SHIFT_BUFSIZE; ++i) {
    if (bb_effect.diff[i]) {
      emit_arith(bb_effect.diff[i], i - MAX_SHIFT_DIST - preshift);
    }
  }

  if (!preshift) {
    emit_shift(bb_effect.ptr_offset);
  }
}

.
%%


int yywrap() { return 1; }

int main(int argc, char *argv[]) {
  if (argc < 2) err("Usage: jit4 <bf file>");

  FILE *fin = fopen(argv[1], "r");
  if (!fin) {
    perror("failed to open file");
    return 1;
  }
  struct stat in_stat;
  stat(argv[1], &in_stat);

  initjit(&state, actions);

  // Function prologue.
  |  mov  eax, [esp+4]
  |  push PTR
  |  mov  PTR, eax
  |  mov  ZERO, 0

  char *buffer = malloc(in_stat.st_size);
  int buf_index;
  char p;
  while ((p = fgetc(fin)) != EOF) {
    switch (p) {
      case '>':
      case '<':
      case '+':
      case '-':
      case '.':
      case ',':
      case '[':
      case ']':
        buffer[buf_index++] = p;
        assert(buf_index <= in_stat.st_size);
    }
  }

  yy_switch_to_buffer(yy_scan_bytes(buffer, buf_index));
  yylex();
  yy_delete_buffer(YY_CURRENT_BUFFER);

  // Function epilogue.
  |  pop  PTR
  |  ret

  void (*fptr)(char*) = jitcode(&state);
  char *mem = calloc(30000, 1);
  fptr(mem);
  free(mem);
  free_jitcode(fptr);
  return 0;
}
