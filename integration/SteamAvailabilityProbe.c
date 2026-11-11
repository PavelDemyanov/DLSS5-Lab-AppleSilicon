#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "Steam API library could not be loaded: %s\n", dlerror()); return 2; }
    bool (*isRunning)(void) = (bool (*)(void))dlsym(library, "SteamAPI_IsSteamRunning");
    if (!isRunning) { fprintf(stderr, "Steam availability API was not found.\n"); return 2; }
    bool running = isRunning();
    printf("{\"steamAPIReachable\":%s}\n", running ? "true" : "false");
    return running ? 0 : 1;
}
