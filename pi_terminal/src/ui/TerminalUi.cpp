#include "TerminalUi.h"
#include "BlurItem.h"
#include "TextFormatter.h"
#include "PetSpriteItem.h"
#include "PetLibrary.h"
#include <vlc-qt-backend/VlcPlayer.h>
#include <vlc-qt-backend/VlcVideoOutput.h>
#include <QtQml/qqml.h>
#include <mutex>

void initializeTerminalUi() {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        qmlRegisterType<BlurItem>("Terminal.Native", 1, 0, "BlurItem");
        qmlRegisterType<TextFormatter>("Terminal.Native", 1, 0, "TextFormatter");
        qmlRegisterType<PetSpriteItem>("Terminal.Native", 1, 0, "PetSpriteItem");
        qmlRegisterType<PetLibrary>("Terminal.Native", 1, 0, "PetLibrary");
        // Always registered: vlc-qt-backend compiles on every platform (stub
        // implementation when libvlc is absent), so VideoBackendVlc.qml can be
        // type-checked everywhere; vlcBackendAvailable() selects the real
        // backend at runtime.
        qmlRegisterType<VlcPlayer>("Terminal.Native", 1, 0, "VlcPlayer");
        qmlRegisterType<VlcVideoOutput>("Terminal.Native", 1, 0, "VlcVideoOutput");
    });
}
