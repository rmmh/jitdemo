%top{
// JIT for Brainf*ck.

#include <stdint.h>
#include <sys/stat.h>

|.arch x64
|.actionlist actions
|
|// Use rbx as our cell pointer.
|// Since rbx is a callee-save register, it will be preserved
|// across our calls to getchar and putchar.
|.define PTR, rbx
|
|// Macro for calling a function.
|// In cases where our target is <=2**32 away we can use
|//   | call &addr
|// But since we don't know if it will be, we use this safe
|// sequence instead.
|.macro callp, addr
|  mov64  rax, (uintptr_t)addr
|  call   rax
|.endmacro

#define Dst &state
#define MAX_NESTING 256

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

}
%%

[<>]+   {
  int count = shiftcount(yytext, yyleng);
  if (count > 0) {
    | add PTR, count
  } else if (count < 0) {
    | sub PTR, -count
  }
}
[-+]+   {
  int count = addcount(yytext, yyleng);
  if (count > 0) {
    | add byte [PTR], count
  } else if (count < 0) {
    | sub byte [PTR], -count
  }
}
"."   {
  |  movzx edi, byte [PTR]
  |  callp putchar
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
  |  cmp  byte [PTR], 0
  |  je   =>(maxpc-2)
  |=>(maxpc-1):
}
"]"   {
  if (top == pcstack) err("Unmatched ']'");
  top--;
  |  cmp  byte [PTR], 0
  |  jne  =>(*top-1)
  |=>(*top-2):
}
"[-]"[+-]*  {
  // zeroing a cell, maybe followed by an explicit set
 | mov byte [PTR], addcount(yytext + 3, yyleng - 3)
}
"["[-+><]*"]" {
  // optimize loops with zero net pointer offset
  // that decrement ptr[0] once
  // i.e., add/sub loops
  if (shiftcount(yytext, yyleng) != 0) {
    REJECT;
  }

  // count the values added to different offsets
  // we assume changed values are within 128 bytes
  // of ptr, and abort otherwise

  uint8_t add_count[257]; // add_count[128] is how much ptr[0] changes by
  memset(add_count, 0, sizeof(add_count));
  int off = sizeof(add_count) / 2;

  for (int i = 1; i < yyleng - 1; ++i) {
    switch(yytext[i]) {
      case '+': add_count[off]++; break;
      case '-': add_count[off]--; break;
      case '<': if (--off < 0) REJECT; break;
      case '>': if (++off >= sizeof(add_count)) REJECT; break;
    }
  }

  // ensure that ptr[0] is decremented once
  if (add_count[128] != (uint8_t)-1) {
    REJECT;
  }

  // only handle a single inc/dec per loc per loop
  for (int i = 0; i < sizeof(add_count); ++i) {
    if (add_count[i] != 0 && add_count[i] != 1 && add_count[i] != (uint8_t)-1) {
      REJECT;
    }
  }

  | mov   al, byte [PTR]

  for (int i = 0; i < sizeof(add_count); ++i) {
    if (add_count[i] == 1) {
      | add byte [PTR+i-128], al
    } else if (add_count[i] == (uint8_t)-1) {
      | sub byte [PTR+i-128], al
    }
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
  |  push PTR
  |  mov  PTR, rdi

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
