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
    if (buf[i] == '+' || buf[i] == '>') {
      ret++;
    } else if (buf[i] == '-' || buf[i] == '<') {
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
  int count = addcount(yytext, yyleng);
  | add PTR, count
}
[-+]+   {
  int count = addcount(yytext, yyleng);
  | add byte [PTR], count
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
