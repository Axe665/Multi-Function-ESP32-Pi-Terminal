#include "TerminalUi.h"
#include "BlurItem.h"
#include "TextFormatter.h"
#include "PetSpriteItem.h"
#include "PetLibrary.h"
#ifdef TERMINAL_VLC_BACKEND
#include "VlcPlayer.h"
#include "VlcVideoOutput.h"
#endif
#include <QtQml/qqml.h>
#include <mutex>

void initializeTerminalUi() {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        qmlRegisterType<BlurItem>("Terminal.Native", 1, 0, "BlurItem");
        qmlRegisterType<TextFormatter>("Terminal.Native", 1, 0, "TextFormatter");
        qmlRegisterType<PetSpriteItem>("Terminal.Native", 1, 0, "PetSpriteItem");
        qmlRegisterType<PetLibrary>("Terminal.Native", 1, 0, "PetLibrary");
#ifdef TERMINAL_VLC_BACKEND
        qmlRegisterType<VlcPlayer>("Terminal.Native", 1, 0, "VlcPlayer");
        qmlRegisterType<VlcVideoOutput>("Terminal.Native", 1, 0, "VlcVideoOutput");
#endif
    });
}
