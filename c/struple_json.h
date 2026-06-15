/* A small JSON value tree + parser (no dependencies). Used by struple_from_json
 * and by the conformance tests to read the corpus. */
#ifndef STRUPLE_JSON_H
#define STRUPLE_JSON_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { SJ_NULL, SJ_BOOL, SJ_INT, SJ_FLOAT, SJ_STRING, SJ_ARRAY, SJ_OBJECT } sj_kind;

typedef struct sj_value sj_value;
struct sj_value {
    sj_kind kind;
    bool bool_val;     /* SJ_BOOL */
    double float_val;  /* SJ_FLOAT */
    char *str;         /* SJ_STRING text, or SJ_INT decimal token (owned, NUL-terminated) */
    sj_value *items;   /* SJ_ARRAY */
    size_t count;
    char **keys;       /* SJ_OBJECT keys (owned) */
    sj_value *vals;    /* SJ_OBJECT values */
    size_t pairs;
};

/* Parse JSON text into a tree (malloc'd), or NULL on error. */
sj_value *struple_json_parse(const char *text, size_t len);
void struple_json_free(sj_value *v);

#ifdef __cplusplus
}
#endif

#endif /* STRUPLE_JSON_H */
