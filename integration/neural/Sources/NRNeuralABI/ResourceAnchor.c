#include "NRNeuralBridge.h"
#include <dlfcn.h>
const char *NRNeuralImagePath(void) {
    Dl_info info;
    if (!dladdr((const void *)&NRNeuralImagePath, &info)) return 0;
    return info.dli_fname;
}
