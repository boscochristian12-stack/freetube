#ifndef FREETUBE_DENO_RUNTIME_BRIDGE_H
#define FREETUBE_DENO_RUNTIME_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

char *freetube_deno_eval(const char *source);
void freetube_deno_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
