// make_vermpq — build a version-check MPQ for realmd to serve over BNFTP.
//   make_vermpq <out.mpq> <local-dll> <archive-name>
// Adds the (Authenticode-signed) CheckRevision DLL into a fresh MPQ under the
// name the client extracts (<mpq-basename>.dll), then applies the Blizzard WEAK
// signature (StormLib has the factored key built in) so SFILE_VerifyFileSignature
// accepts it. See src/realmd/assets/README.md.
#include <StormLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s <out.mpq> <local-dll> <archive-name>\n", argv[0]); return 2; }
    const char *out = argv[1], *dll = argv[2], *arcname = argv[3];
    remove(out);

    HANDLE hMpq = NULL;
    if (!SFileCreateArchive(out, MPQ_CREATE_LISTFILE | MPQ_CREATE_ATTRIBUTES, 16, &hMpq)) {
        fprintf(stderr, "SFileCreateArchive failed: %u\n", errno); return 1;
    }
    if (!SFileAddFileEx(hMpq, dll, arcname, MPQ_FILE_COMPRESS, MPQ_COMPRESSION_ZLIB, MPQ_COMPRESSION_ZLIB)) {
        fprintf(stderr, "SFileAddFileEx failed: %u\n", errno); SFileCloseArchive(hMpq); return 1;
    }
    if (!SFileSignArchive(hMpq, SIGNATURE_TYPE_WEAK)) {
        fprintf(stderr, "SFileSignArchive(WEAK) failed: %u\n", errno); SFileCloseArchive(hMpq); return 1;
    }
    if (!SFileCloseArchive(hMpq)) {
        fprintf(stderr, "SFileCloseArchive failed: %u\n", errno); return 1;
    }
    printf("wrote %s (weak-signed, contains %s)\n", out, arcname);
    return 0;
}
