#include <stddef.h>
extern void* malloc(size_t);
extern void  free(void*);
/* debug allocator shims -> release CRT */
void* _malloc_dbg(size_t size, int blockType, const char* file, int line){
    (void)blockType;(void)file;(void)line; return malloc(size);
}
void _free_dbg(void* p, int blockType){ (void)blockType; free(p); }
/* debug report/check no-ops (return previous/success) */
int _CrtSetReportMode(int reportType, int reportMode){ (void)reportType;(void)reportMode; return 0; }
size_t _CrtSetCheckCount(size_t chkCount){ (void)chkCount; return 0; }
