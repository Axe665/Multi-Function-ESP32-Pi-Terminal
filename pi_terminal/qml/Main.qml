import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtWebEngine 2.0
import QtQuick.Dialogs
import Terminal.Native 1.0
import "TimeMath.js" as TimeMath

ApplicationWindow {
    id: win
    visible: true; width: 1280; height: 800
    minimumWidth:320;minimumHeight:320
    title: I18n.t("模块化终端"); color: Theme.background
    // 报告 §14：大字号模式在界面缩放之上再放大一档，但仍受 Theme 的
    // 48px 热区下限约束（热区用 Math.max，不会被放大到越界）。
    property real textScale: systemTools.interfaceScale * (systemTools.largeText ? 1.15 : 1.0)
    // 指针表盘配色：auto = 跟随当地白天/夜晚，light = 常白，dark = 常黑。
    // 存在 time/clock-face（与时间页其它设置同一个前缀），时间页与设置分区共用这一份。
    property string clockFace: systemTools.settingsRead("time/clock-face", "auto")
    onClockFaceChanged: systemTools.settingsWrite("time/clock-face", clockFace)
    // 时间格式：24 = 24 小时制，12 = 上午/下午。
    property string timeFormat: systemTools.settingsRead("time/format", "24")
    onTimeFormatChanged: systemTools.settingsWrite("time/format", timeFormat)
    readonly property bool efficientRendering: systemTools.energySaving
    readonly property Item blurBackdropItem: desktopBackground
    property bool repairBackdropOnly:false
    property bool repairRawWallpaper:false
    property bool repairRawDefault:false
    property bool repairRawQuickBlur:false
    property bool repairRawAppBlur:false
    property var repairUsbDevices:null
    readonly property var fileRemovableDevices:repairUsbDevices===null?systemTools.removableDevices:repairUsbDevices
    property var repairEnergyTrace:[]
    property string observedWallpaperUrl:""
    property string observedUiLanguage:""
    property int appBackdropRefreshCount:0
    readonly property Item panelBlurTexture:panelBlurCache.activeTexture
    property bool blurInputReady:false
    property bool connectionSettingsOpen:false
    property bool developerPanelOpen:false
    property bool testModeOpen:false
    property bool aboutDeviceOpen:false
    property bool networkPermissionsOpen:false
    property bool startupInterfaceReady:false
    property bool startupComplete:false
    // 删账户的等待层是否正在显示（由 userSecurityView 的 accountDeleted 打开）。
    property bool deletingAccount:false
    // 键盘避让：聚焦输入框被浮动键盘盖住时，内容整体上移刚好的距离。
    // 宠物菜单那套是「缩小容器到键盘上方」，全屏页面不能缩，只能位移。
    property real keyboardShift:0
    // 供 Popup 自己避让用：它们在 overlay 上，不在 pages 里，吃不到上面的位移。
    readonly property var virtualKeyboard: screenKeyboard

    function updateKeyboardShift() {
        if (!screenKeyboard || !screenKeyboard.visible) { keyboardShift = 0; return }
        const focusItem = win.activeFocusItem
        if (!focusItem) { keyboardShift = 0; return }
        // 用「未偏移」的位置算，否则位移会自己把自己越推越远。
        const rawBottom = focusItem.mapToItem(win.contentItem, 0, focusItem.height).y + keyboardShift
        const keyboardTop = screenKeyboard.y
        const overlap = rawBottom + 12 * uiScale - keyboardTop
        keyboardShift = Math.min(Math.max(0, overlap), screenKeyboard.height + 24 * uiScale)
    }
    // 启动后 8 秒内的日志（音频设备切换等）不弹横幅，只进运行记录。
    property double bootAt:Date.now()
    // 登入门禁 + 锁屏 + 无交互自动锁：未登录时挡住整个桌面。
    SessionGate {
        id:sessionGate
        parent:Overlay.overlay
        z:20000
        // 首次开机向导激活时门禁让位：此时没有任何用户，登录页只会显示
        // “请先在终端执行 --init-admin”，与向导重复且会抢焦点。
        enabledGate:(typeof sessionGateBypassed !== "undefined" ? !sessionGateBypassed : true)
                    && !onboarding.active
        inputSource:win
        onKeyboardRequested: screenKeyboard.show()
    }
    // 首次开机向导（OOBE）：注册表为空时接管启动。
    // splash（z=10000）结束后才加载，避免两个全屏层叠加；
    // z=50000 压在门禁（20000）与所有应用弹窗（40000+）之上。
    Loader {
        id:onboardingLoader
        parent:Overlay.overlay
        anchors.fill:parent
        z:50000
        // 删账户的等待层没走完之前先别把向导拉起来，否则两个全屏层会抢同一帧。
        active:onboarding.active && win.startupComplete && !win.deletingAccount
        source:active?"OnboardingWizard.qml":""
        onLoaded:if(item)item.hostWindow=win
    }
    // 删账户后的等待层：至少 4 秒，再放行下一个界面（首次开机向导 / 登录页 / 账户列表）。
    // 删除本身是同步调用，计时从「删完」那一刻开始；z 压在应用弹窗之上、向导之下。
    Timer {
        id:accountDeleteWaitTimer
        interval:4000
        onTriggered:win.deletingAccount=false
    }
    AdminDeleteWait {
        id:accountDeleteWait
        parent:Overlay.overlay
        anchors.fill:parent
        z:45000
        visible:win.deletingAccount
    }
    Connections {
        target:userSecurityView
        function onAccountDeleted(lastAdmin) {
            win.deletingAccount=true
            accountDeleteWaitTimer.restart()
        }
    }
    // 访客点灰显入口时的"无权限"说明。z 必须高于 SessionGate(20000)，
    // 因为 Popup 渲染在窗口 overlay 上，z 不跟随父元素。
    //
    // 这里刻意不用 Qt Quick Layouts：ColumnLayout + 换行文本在 DPR 2 下会让
    // "文本高度 ↔ 弹窗可用高度"互相反馈，稳定触发 Layout polish loop，
    // 表现为点灰卡直接卡死（实测日志每秒刷几十行）。改成固定高度 + 普通
    // Column/Row + 显式宽度，隐式高度不参与弹窗定高，彻底断开反馈。
    Dialog {
        id:restrictedNotice;objectName:"restrictedAccessDialog"
        parent:Overlay.overlay;z:40000;modal:true
        x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(520*uiScale,win.width-Theme.gap*2)
        height:Math.min(280*uiScale,win.height-Theme.gap*2)
        padding:Theme.shapeExtraLarge
        // 用不透明深色卡片而不是 GlassSurface：弹窗背后是亮色壁纸/磨砂首页，
        // 玻璃层会把底色冲淡，白字对比度不够（实测发灰）。
        background:Rectangle {color:Theme.surface;radius:Theme.shapeExtraLarge;border.width:1;border.color:Theme.outline}
        property string entryTitle:""
        readonly property real innerWidth:width-padding*2
        function show(title){entryTitle=title;open()}
        contentItem:Column {
            width:restrictedNotice.innerWidth
            spacing:Theme.gap
            Row {
                spacing:Theme.gap/1.5
                MaterialIcon {width:26*uiScale;height:width;name:"lock"}
                CarText {text:I18n.t("无权限");heading:true}
            }
            CarText {
                width:parent.width
                wrapMode:Text.Wrap
                text:I18n.t("访客会话无法访问")+"「"+restrictedNotice.entryTitle+"」"+I18n.t("。请退出访客会话后使用管理员或普通用户账户登录。")
            }
            Item {
                width:parent.width
                height:restrictedOkButton.height
                CarButton {id:restrictedOkButton;objectName:"restrictedNoticeOk"
                    anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter
                    text:I18n.t("知道了");accent:true;onClicked:restrictedNotice.close()}
            }
        }
    }
    // 开发者选项：仅管理员可见（入口在设置里），全英文、原样输出。
    DeveloperPanel {
        id:developerPanel
        // 挂在 contentItem 上：ui-audit 用 findControl(contentItem,"energySwitch") 找节能开关。
        parent:win.contentItem
        width:parent?parent.width:win.width
        height:parent?parent.height:win.contentItem.height
        open:win.developerPanelOpen
        onCloseRequested:win.developerPanelOpen=false
        onKeyboardRequested:screenKeyboard.show()
    }
    TestModePanel {
        id:testModePanel
        parent:Overlay.overlay
        width:parent?parent.width:win.width
        height:parent?parent.height:win.contentItem.height
        open:win.testModeOpen
        onCloseRequested:win.testModeOpen=false
    }
    // 锁屏即撤销前台读取（f-day1 §2）：模块页可能显示传感器读数，必须卸载。
    // 不用 visible:false —— 那只是不画，数据仍在内存里可读。
    Connections {
        target: sessionManager
        function onLockStateChanged() {
            if (sessionManager.locked) {
                modulePageHost.unload()
                activeSession=""
                activeActions=[]
            }
        }
        function onSessionInvalidated() {
            // 退出登录 / 删掉最后一个账户：先回到桌面首页。删号后向导会
            // 重新接管（onboarding.rearm），否则向导关掉时会停在已删账户的
            // 页面（例如用户与权限）上。
            win.phase = "home"
            win.section = 0
            modulePageHost.unload()
            activeSession = ""
            activeActions = []
        }
        function onChanged() {
            // 会话切换（正式用户 ↔ 临时访客）会改变可见应用集合：
            // 访客看不到设置/连接管理/用户与权限。卡片表必须跟着重建，
            // 否则登录后仍是启动时那份（登出状态的）列表。
            syncCards()
            // 最近使用是内存 ListModel（不落盘），但它跨会话存活：
            // 访客打开过什么会留给下一个登录的人看。登出即清。
            if (!sessionManager.loggedIn) recentApps.clear()
        }
    }
    Connections {
        target: networkPolicy
        function onChanged() { win.applyModulePermissions() }
    }
    Connections {
        target: modulePageHost
        function onFileWriteAccessRequested(instance, packageId) {
            win.pendingWriteInstance = instance
            writeScopeDialog.title = I18n.t("选择模块可写位置") + " · " + packageId
            writeScopeDialog.open()
        }
    }
    Dialog {
        id: writeScopeDialog
        modal: true
        closePolicy: Popup.CloseOnEscape
        x: (win.width - width) / 2
        y: (win.height - height) / 2
        width: Math.min(520 * Theme.scaleFactor, win.width - Theme.gap * 4)
        padding: Theme.gap
        background: GlassSurface { color: Theme.surface; radius: Theme.shapeLarge; borderColor: Theme.outline; borderWidth: 1 }
        contentItem: ColumnLayout {
            spacing: Theme.gap
            CarText { Layout.fillWidth: true; heading: true; text: writeScopeDialog.title }
            CarText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                fontPixelSize: Theme.fontCaption
                subdued: true
                text: I18n.t("模块只能写入你选中的单个文件或目录；授权默认 24 小时后失效。")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap / 2
                CarButton {
                    Layout.fillWidth: true
                    text: I18n.t("选择单个文件")
                    onClicked: { writeScopeDialog.close(); moduleWriteFileDialog.open() }
                }
                CarButton {
                    Layout.fillWidth: true
                    text: I18n.t("选择目录")
                    onClicked: { writeScopeDialog.close(); moduleWriteFolderDialog.open() }
                }
                CarButton {
                    text: I18n.t("取消")
                    onClicked: { win.pendingWriteInstance = ""; writeScopeDialog.close() }
                }
            }
        }
    }
    FolderDialog {
        id: moduleWriteFolderDialog
        title: I18n.t("选择模块可写目录")
        onAccepted: {
            if (win.pendingWriteInstance !== win.activeSession) return
            const path = decodeURIComponent(selectedFolder.toString().replace("file://", ""))
            modulePageHost.grantFileWrite(path)
            win.announce(I18n.t("已授权模块写入所选目录"))
        }
        onRejected: win.pendingWriteInstance = ""
    }
    FileDialog {
        id: moduleWriteFileDialog
        title: I18n.t("选择模块可写文件")
        fileMode: FileDialog.OpenFile
        onAccepted: {
            if (win.pendingWriteInstance !== win.activeSession) return
            const path = decodeURIComponent(selectedFile.toString().replace("file://", ""))
            modulePageHost.grantFileWrite(path)
            win.announce(I18n.t("已授权模块写入所选文件"))
        }
        onRejected: win.pendingWriteInstance = ""
    }
    Loader {
        id:startupLoader
        parent:Overlay.overlay
        anchors.fill:parent
        // 启动进度必须盖在登录/锁屏（SessionGate z=20000）之上，
        // 否则冷启动时用户只看到登录页、看不到加载进度，像“卡住”。
        z:21000
        active:!win.startupComplete
        focus:active
        sourceComponent:StartupSplash {
            interfaceReady:win.startupInterfaceReady
            wallpaperReady:homeWallpaper.source.toString()==="" || homeWallpaper.status===Image.Ready || homeWallpaper.status===Image.Error
            wallpaperFailed:homeWallpaper.status===Image.Error
            frameReady:win.blurInputReady
            cacheReady:windowBlurCache.ready && panelBlurCache.ready
            onFinished:{
                console.info("STARTUP_READY",JSON.stringify({cacheReady:cacheReady,usingFallback:usingFallback,progress:progress}))
                win.startupComplete=true
            }
        }
    }
    function startupSnapshot() {
        const splash=startupLoader.item
        const content=splash?findControl(splash,"startupContent"):null
        return JSON.stringify({complete:startupComplete,overlayLoaded:splash!==null,
            progress:splash?splash.progress:1,steps:splash?splash.completedSteps:4,
            status:splash?splash.statusText:"",language:systemTools.uiLanguage,energy:systemTools.energySaving,
            focused:splash?splash.activeFocus:false,
            cacheReady:windowBlurCache.ready&&panelBlurCache.ready,
            usingFallback:splash?splash.usingFallback:false,
            minimumElapsed:splash?splash.minimumElapsed:true,frameReady:splash?splash.frameReady:blurInputReady,
            canFinish:splash?splash.canFinish:true,overlayOpacity:splash?splash.opacity:0,
            content:content?{x:content.x,y:content.y,width:content.width,height:content.height}:null,
            width:win.width,height:win.height})
    }
    function repairCaptureStartup(path) {
        if(startupLoader.item)startupLoader.item.grabToImage(function(result){result.saveToFile(path)})
    }
    Connections {target:win
        function onFrameSwapped(){if(!win.blurInputReady)win.blurInputReady=true}
        function onSceneGraphInvalidated(){win.blurInputReady=false;if(windowBlurCache)windowBlurCache.invalidate();if(panelBlurCache)panelBlurCache.invalidate()}
    }
    onRepairRawWallpaperChanged:{windowBlurCache.requestUpdate();panelBlurCache.requestUpdate()}
    onRepairRawDefaultChanged:{windowBlurCache.requestUpdate();panelBlurCache.requestUpdate()}
    function findControl(item,name) {
        if(!item)return null
        if(item.objectName===name)return item
        // Qt 6.4's QML list wrappers are not reliably iterable with for...of.
        const childItems=item.children
        if(!childItems)return null
        for(let i=0;i<childItems.length;++i){const found=findControl(childItems[i],name);if(found)return found}
        return null
    }
    function repairSetup(spec) {
        systemTools.setEnergySaving(spec.energy)
        repairEnergyTrace=[systemTools.energySaving]
        if(spec.startup)systemTools.setUiLanguage(spec.language||"zh")
        else {
            systemTools.setUiLanguage("zh")
            if(spec.language==="en")findControl(win.contentItem,"englishChoose").clicked()
        }
        systemTools.setLauncherOpacity(spec.opacity===undefined?0.65:spec.opacity)
        systemTools.setModuleOpacity(spec.opacity===undefined?0.65:spec.opacity)
        if(spec.scale)systemTools.setInterfaceScale(spec.scale)
        if(spec.wallpaper)systemTools.setWallpaper(spec.wallpaper)
        if(spec.resetWallpaper)systemTools.setWallpaper("")
        repairBackdropOnly=!!spec.backdrop;repairRawWallpaper=!!spec.raw;repairRawDefault=!!spec.rawDefault;repairRawQuickBlur=!!spec.rawQuickBlur;repairRawAppBlur=!!spec.rawAppBlur
        if(spec.voiceTest) systemTools.setVoiceTestMode(true)
        if(spec.eggPopup) Qt.callLater(function(){voiceTestConfirm.open()})
        if(spec.page) auditPage(spec.page)
        if(spec.cacheMaximized)appMaximized=true
        if(spec.cacheLayout)cacheLayoutAuditTimer.start()
        if(spec.usbScenario){
            repairUsbDevices=[{id:"fixture1",name:"USB Music",mounted:true,location:"@usb/fixture1"},{id:"fixture2",name:"USB Photos",mounted:false,location:"@usb/fixture2"}]
            if(spec.usbScenario==="insert"){usbInsertDialog.deviceName="USB Music";usbInsertDialog.deviceId="fixture1";usbInsertDialog.open()}
        }
        if(spec.musicScenario) Qt.callLater(function() { findControl(win.contentItem,"musicPlayerPage").auditMusicScenario(spec.musicScenario) })
        if(spec.wallpaperAfterOpen){
            if(!spec.page)auditPage(1)
            Qt.callLater(function(){systemTools.setWallpaper(spec.wallpaperAfterOpen)})
        }
        if(spec.resetWallpaperAfterOpen){
            if(!spec.page)auditPage(1)
            Qt.callLater(function(){systemTools.setWallpaper("")})
        }
        if(spec.picker)findControl(win.contentItem,"wallpaperChoose").clicked()
        if(spec.pickerNavigate){
            wallpaperPicker.open()
            repairPickerNavigationTimer.start()
        }
        if(spec.quickPanel)showDevicePanel(false)
        if(spec.volumePanel){showDevicePanel(false);findControl(devicePanel.contentItem,"quickVolumeTile").clicked()}
        if(spec.soundSettings)settingsQuery=systemTools.uiLanguage==="en"?"sound":"声音"
        if(spec.quickGlass)notices.insert(0,{title:"Preview notification",message:"Position-matched background blur",appName:"Terminal",iconName:"notifications",time:"12:00",read:true,important:false})
        if(spec.quickMedia) {
            auditPage(spec.quickMedia==="video"?10:9)
            musicPage.queue=[{name:"Preview music",title:"Preview music",artist:"Local audio",relative:"preview.wav"}]
            musicPage.playEntry(0)
            if(spec.quickMedia==="video") videoPage.playFile("preview.mp4","Preview video")
            repairMediaAction=spec.mediaAction||""
            repairMediaTimer.start()
            showDevicePanel(false)
        }
        if(spec.editorScenario) {auditPage(8);noteEditor.text=documentFormatter.richText("Material Design\nRaspberry Pi document",false);noteEditor.select(0,8);documentFormatter.format(noteEditor.textDocument,0,8,"bold");noteEditor.select(0,0)}
        if(spec.fileEditor) {filePath="preview.html";fileEditable=true;viewer.text=documentFormatter.richText("Document preview\nRaspberry Pi",false);fileDialog.open()}
        if(spec.energyToggles) {
            const sw=findControl(win.contentItem,"energySwitch")
            for(let i=0;i<spec.energyToggles;++i){sw.clicked();repairEnergyTrace.push(systemTools.energySaving)}
        }
        if(spec.keyboard){
            if(spec.keyboardInput){noteEditor.text="";noteEditor.forceActiveFocus()}
            screenKeyboard.show()
            Qt.callLater(function(){
                screenKeyboard.pinyin=spec.pinyin||"nihao";screenKeyboard.ensureDictionaryLoaded()
                if(spec.keyboardInput){
                    systemTools.captureKeyboardTargetItem(noteEditor)
                    screenKeyboard.finishComposition()
                    keyboardInputPass=noteEditor.getText(0,noteEditor.length)==="你好"
                    screenKeyboard.backspace();screenKeyboard.chineseMode=false;screenKeyboard.typeLetter("a")
                    keyboardInputPass=keyboardInputPass&&noteEditor.getText(0,noteEditor.length)==="你a"
                    screenKeyboard.chineseMode=true;screenKeyboard.pinyin="nihao"
                }
                screenKeyboard.x=-1000;screenKeyboard.y=-1000;screenKeyboard.clampPosition()
                keyboardBoundsPass=screenKeyboard.x>=0&&screenKeyboard.y>=0
                screenKeyboard.x=10000;screenKeyboard.y=10000;screenKeyboard.clampPosition()
                keyboardBoundsPass=keyboardBoundsPass&&screenKeyboard.x+screenKeyboard.width<=screenKeyboard.parent.width&&screenKeyboard.y+screenKeyboard.height<=screenKeyboard.parent.height
                screenKeyboard.positionNearBottom()
            })
        }
    }
    function repairSnapshot() {
        const texts=[],untranslated=[],keyboardBounds=[],launcherCardSamples=[],usbButtons=[]
        function visit(item) {
            if(item.objectName==="browserWebView" || item.objectName==="videoFileList" || item.objectName==="musicFileList" || item.objectName==="musicResultList" || item.objectName==="musicNowPlayingTitle" || item.objectName==="musicNowPlayingArtist")return // Website text and local/online media metadata are user content.
            if(item.objectName==="launcherCardBackdrop")launcherCardSamples.push({x:item.sourceRect.x,y:item.sourceRect.y,width:item.sourceRect.width,height:item.sourceRect.height})
            if(!item.visible)return
            if(item.objectName==="usbDeviceButton"){
                const p=item.mapToItem(filesSidebar,0,0)
                usbButtons.push({name:item.modelData.name,y:p.y,height:item.height,viewport:filesSidebar.height})
            }
            if(item.text!==undefined && typeof item.text==="string" && item.text.length) {
                texts.push(item.text)
                if(systemTools.uiLanguage==="en" && /[\u4e00-\u9fff]/.test(item.text) && item.text!==I18n.t("简体中文") && item.text!==I18n.t("中") && !item.readOnly && item.inputMethodHints===undefined)untranslated.push(item.text)
            }
            if(item.objectName==="letterKey" || item.objectName==="candidateButton" || item.objectName==="keyboardClose") {
                const point=item.mapToItem(screenKeyboard.contentItem,0,0)
                keyboardBounds.push({name:item.objectName,x:point.x,y:point.y,width:item.width,height:item.height})
            }
            const childItems=item.children
            if(childItems)for(let i=0;i<childItems.length;++i)visit(childItems[i])
        }
        visit(win.contentItem)
        if(screenKeyboard.visible)visit(screenKeyboard.contentItem)
        const canvasPoint=paintCanvas.mapToItem(win.contentItem,0,0)
        const backdropPoint=appShell.mapToItem(desktopBackground,0,0)
        const quickGlass=[]
        for(const name of ["quickPanelBlur","quickHotspotBlur","quickBluetoothBlur","quickSystemBlur","quickVolumeBlur","quickMediaBlur","quickNotificationBlur"]){
            const surface=findControl(devicePanel.contentItem,name)||findControl(devicePanel.background,name)
            if(!surface||!surface.visible)continue
            const p=surface.mapToItem(surface.backdrop,0,0)
            const blur=findControl(surface,"globalSurfaceBlur")
            quickGlass.push({name:name,sample:surface.sampleRect,x:p.x,y:p.y,width:surface.width,height:surface.height,levels:blur.levels,resolution:blur.resolutionScale,enabled:surface.blurEnabled,live:surface.sampleLive,cached:blur.preblurred})
        }
        return JSON.stringify({energy:systemTools.energySaving,language:systemTools.uiLanguage,
            startup:JSON.parse(startupSnapshot()),
            energySwitch:findControl(win.contentItem,"energySwitch").checked,energyTrace:repairEnergyTrace,
            wallpaperReady:homeWallpaper.status===Image.Ready,wallpaperUrl:systemTools.wallpaper.toString(),wallpaperBlur:findControl(win.contentItem,"customWallpaperBlur").visible,
            homeBlur:findControl(win.contentItem,"customWallpaperBlur").visible||findControl(win.contentItem,"backgroundGpuBlur").visible,
            appBlur:appShell.visible&&findControl(win.contentItem,"windowBackdropBlur").visible&&findControl(win.contentItem,"moduleBackgroundBlur").visible,
            appBackdropLive:windowBackdrop.live,appBackdropRect:windowBackdrop.sourceRect,
            appBackdropExpected:{x:backdropPoint.x,y:backdropPoint.y,width:appShell.width,height:appShell.height},
            blurCache:{windowReady:windowBlurCache.ready,panelReady:panelBlurCache.ready,windowGeneration:windowBlurCache.generation,panelGeneration:panelBlurCache.generation,windowRevision:windowBlurCache.activeTexture?windowBlurCache.activeTexture.renderRevision:-1,panelRevision:panelBlurCache.activeTexture?panelBlurCache.activeTexture.renderRevision:-1,windowAlpha:windowBlurCache.activeTexture?windowBlurCache.activeTexture.sampledAlpha:-1,panelAlpha:panelBlurCache.activeTexture?panelBlurCache.activeTexture.sampledAlpha:-1,windowWidth:windowBlurCache.activeTexture?windowBlurCache.activeTexture.width:0,panelWidth:panelBlurCache.activeTexture?panelBlurCache.activeTexture.width:0},
            appBackdropRefreshCount:appBackdropRefreshCount,
            launcherCardSamples:launcherCardSamples,
            launcherCardBlur:findControl(win.contentItem,"launcherBackdropBlur")?findControl(win.contentItem,"launcherBackdropBlur").visible:false,
            statusDockBlur:win.footer && findControl(win.footer,"statusDockBlur")?findControl(win.footer,"statusDockBlur").visible:false,
            quickCardBlur:findControl(devicePanel.contentItem,"quickHotspotBlur")?findControl(devicePanel.contentItem,"quickHotspotBlur").blurEnabled:false,
            quickBackdropAttached:findControl(devicePanel.contentItem,"quickHotspotBlur")?findControl(devicePanel.contentItem,"quickHotspotBlur").backdrop!==null:false,
            quickGlass:quickGlass,
            volumeControl:{expanded:devicePanel.volumeExpanded,available:systemTools.systemVolume.available,volume:systemTools.systemVolume.volume,muted:systemTools.systemVolume.muted,
                systemX:findControl(devicePanel.contentItem,"quickSystemTile").x,systemY:findControl(devicePanel.contentItem,"quickSystemTile").y,systemWidth:findControl(devicePanel.contentItem,"quickSystemTile").width,
                volumeX:findControl(devicePanel.contentItem,"quickVolumeTile").x,volumeY:findControl(devicePanel.contentItem,"quickVolumeTile").y,
                sliderEnabled:systemVolumeSlider.enabled,sliderHeight:systemVolumeSlider.height,sliderWidth:systemVolumeSlider.width},
            audioFocus:{enabled:systemTools.duckMediaForSpeech,active:systemTools.speechActive,gain:systemTools.mediaGain,musicVolume:musicPage.volume,videoVolume:videoPage.volume},
            blurSourceSize:{width:desktopBackground.width,height:desktopBackground.height},
            musicPalette:musicPage.auditMusicPalette(),
            firstBlurCapturePosition:devicePanel.firstBlurCapturePosition,
            quickTileSize:{width:findControl(devicePanel.contentItem,"quickHotspotTile").width,height:findControl(devicePanel.contentItem,"quickHotspotTile").height,statusWidth:(quickStatusGrid.width-quickStatusGrid.columnSpacing*(quickStatusGrid.columns-1))/quickStatusGrid.columns,statusHeight:88*uiScale},
            mediaCard:{visible:findControl(devicePanel.contentItem,"quickMediaCard").visible,video:devicePanel.mediaVideo,playing:devicePanel.media.mediaPlaying,position:devicePanel.media.mediaPosition,duration:devicePanel.media.mediaDuration,musicPlaying:musicPage.mediaPlaying,videoPlaying:videoPage.mediaPlaying,background:!devicePanel.media.active},
            editorMetrics:{height:noteEditor.height,y:noteEditor.y,topPadding:noteEditor.topPadding,cursor:noteEditor.positionToRectangle(0),scrollY:notesScroll.contentItem.contentY,viewportHeight:notesScroll.height},
            powerMode:systemTools.deviceStatus.powerMode||"other",powerIcon:win.footer?findControl(win.footer,"statusPowerIcon").name:"",
            powerText:win.footer?findControl(win.footer,"statusPowerText").text:"",
            powerIconCases:win.footer?({battery:win.footer.powerIconFor({powerMode:"battery",batteryState:"Discharging",batteryPercent:54}),charging:win.footer.powerIconFor({powerMode:"battery",batteryState:"Charging",batteryPercent:54}),external:win.footer.powerIconFor({powerMode:"external",batteryPercent:-1}),other:win.footer.powerIconFor({powerMode:"other",batteryPercent:-1})}):({}),
            backdropLevels:findControl(win.contentItem,"backgroundGpuBlur").levels,
            windowOpacity:appShell.opacity,tintOpacity:findControl(win.contentItem,"windowTint").opacity,
            maximized:appMaximized,page:section,picker:wallpaperPicker.visible,wallpaperFolder:wallpaperFolder,quickDate:localizedLongDate,
            texts:texts,untranslated:untranslated,
            languageSamples:[I18n.t("浏览器"),I18n.t("文件"),I18n.t("设置"),I18n.t("计算器"),I18n.t("画图"),I18n.t("文本便笺"),I18n.t("选择图片"),I18n.t("节能模式")],
            usbButtons:usbButtons,usbPrompt:usbInsertDialog.visible,
            keyboard:{visible:screenKeyboard.visible,internal:screenKeyboard.contentItem.Window.window===win,x:screenKeyboard.x,y:screenKeyboard.y,hostWidth:screenKeyboard.parent.width,hostHeight:screenKeyboard.parent.height,width:screenKeyboard.width,height:screenKeyboard.height,bounds:keyboardBounds,candidates:screenKeyboard.currentCandidates,clampPassed:keyboardBoundsPass,inputPassed:keyboardInputPass},
            recommendations:{ni:systemTools.pinyinCandidates("ni"),hao:systemTools.pinyinCandidates("hao"),nihao:systemTools.pinyinCandidates("nihao"),zhongguo:systemTools.pinyinCandidates("zhongguo"),women:systemTools.pinyinCandidates("women"),sentence:systemTools.pinyinCandidates("nihaozhongguo")},
            paint:{x:canvasPoint.x,y:canvasPoint.y,width:paintCanvas.width,height:paintCanvas.height,strokes:paintStrokes.map(function(s){return s.points.length}),inputSamples:paintCanvas.inputSamples}}
            )
    }
    function repairCaptureKeyboard(path) {if(screenKeyboard.visible)screenKeyboard.contentItem.grabToImage(function(result){result.saveToFile(path)})}
    Component {id:cacheProbeComponent;CachedBlur {source:win.panelBlurTexture;preblurred:true;width:desktopBackground.width;height:desktopBackground.height;x:-width*2}}
    function repairCaptureCacheProbe(path) {
        const probe=cacheProbeComponent.createObject(win.contentItem)
        probe.grabToImage(function(result){result.saveToFile(path);probe.destroy()})
    }
    function blurPerformanceSetup(energy) {
        systemTools.setEnergySaving(energy)
        devicePanel.close();appMaximized=false;auditPage(3)
    }
    function blurPerformanceAction(action) {
        if(action==="maximize")toggleMaximize()
        else if(action==="restore")toggleMaximize()
        else if(action==="panel-open")showDevicePanel(false)
        else if(action==="panel-change")notices.insert(0,{title:"Blur benchmark",message:"Layout changes must retain valid textures",appName:"Terminal",iconName:"notifications",time:"12:00",read:true,important:false})
        else if(action==="panel-close")devicePanel.close()
    }
    BlurItem {id:blurCounters;visible:false}
    function blurPerformanceStats() {return JSON.stringify(blurCounters.renderingStats())}
    property string repairMediaAction:""
    property bool keyboardBoundsPass:false
    property bool keyboardInputPass:false
    Timer {id:cacheLayoutAuditTimer;interval:1800;onTriggered:{
        notices.insert(0,{title:"Cache layout change",message:"New content must reuse the completed background texture",appName:"Terminal",iconName:"notifications",time:"12:01",read:true,important:false})
        devicePanel.refreshStaticBlur()
    }}
    Timer {id:repairMediaTimer;interval:1600;onTriggered:{
        win.auditPage(3) // Exercise a real foreground-to-background transition.
        if(repairMediaAction==="pause")devicePanel.media.pauseMedia()
        else if(repairMediaAction==="resume"){devicePanel.media.pauseMedia();devicePanel.media.toggleMedia()}
    }}
    Timer {id:repairPickerNavigationTimer;interval:500;onTriggered:{
        const directory=systemTools.files("").find(function(entry){return entry.directory})
        if(directory)activateWallpaperEntry(directory)
    }}
    property bool renderBenchmark: false
    SequentialAnimation {
        running: win.renderBenchmark; loops: Animation.Infinite
        NumberAnimation { target: launcher; property: "contentX"; from: 0; to: Math.min(3,launcher.pageCount-1)*launcher.width; duration:2500; easing.type:Easing.InOutSine }
        NumberAnimation { target: launcher; property: "contentX"; from: Math.min(3,launcher.pageCount-1)*launcher.width; to:0; duration:2500; easing.type:Easing.InOutSine }
    }
    // Fit the complete desktop layout to the available logical screen size.
    // The previous lower clamp of 1 prevented any down-scaling, so compact
    // panels such as the Pi's 1024x600 display clipped the content while the
    // UI still reported that it was adapting automatically.
    readonly property real autoScale: Math.max(0.65, Math.min(1.4, Math.min(width / 1280, height / 800)))
    readonly property real uiScale: autoScale * textScale
    readonly property bool narrow: width < 760 * uiScale
    readonly property bool shortScreen: height < 760 * uiScale
    // At 360dp + large text there is not enough width for four 48dp browser
    // actions plus a usable address field. Drop the redundant "go" action
    // (Enter/onAccepted still navigates) instead of letting the field collapse.
    readonly property bool compactBrowserToolbar: width < 520 * uiScale
    readonly property real edge: width < 600 ? Theme.gap : Theme.margin
    font.pointSize: Theme.body
    // 有输入就重置锁屏计时（5 分钟无交互自动锁）。
    onActiveChanged: if(sessionGate) sessionGate.noteInput()
    onActiveFocusItemChanged: {
        if(sessionGate) sessionGate.noteInput()
        const target=activeFocusItem
        if(target && target.inputMethodHints!==undefined && target.text!==undefined && !target.readOnly)
            systemTools.captureKeyboardTargetItem(target)
    }
    Material.theme: Material.Dark; Material.accent: Theme.accent; Material.foreground: Theme.foreground
    Binding { target: Theme; property: "scaleFactor"; value: win.uiScale }
    property int section: 0
    // 浏览器懒加载：第一次打开浏览器才创建 WebEngineView（渲染进程）。
    // 主页/天气/媒体等页面不再在启动时就拉起 WebEngine。
    property bool browserLoaded: false
    onSectionChanged: if(section===2) browserLoaded=true
    property string phase:"home"
    property real openProgress:0
    property real originX:width/2
    property real originY:height/2
    property string appTitle:""
    property string appIcon:"apps"
    property string appEntryId:""
    property bool appMinimized:false
    property bool appMaximized:false
    property bool videoFullscreen:false
    property bool petEasterEggEnabled:false
    property bool appMinimizeAnimating:false
    readonly property bool appSurfaceVisible:appShell.visible
    readonly property real appSurfaceWidth:appShell.width
    property var openTaskIds: []
    ListModel {id:openTasks}
    property var pendingLaunch:null
    property var releaseQueue:[]
    property int homeRevision:0
    property int unreadNotifications:0
    property string bannerTitle:""
    property string bannerMessage:""
    property string bannerAppName:I18n.t("模块化终端")
    property string bannerIconName:"notifications"
    property string bannerTime:""
    property bool bannerImportant:false
    property string bookmarkFilter:""
    property string settingsQuery:""
    // 设置主页的二级页索引：-1 = 主页；0..9 = 分类页。
    property int settingsSection:-1
    // 设置主页分类卡片。match 只用于搜索过滤；adminOnly / hideForGuest
    // 沿用原分组的可见规则（开发者选项只给管理员，关于本机不给访客）。
    readonly property var settingsCards:[
        {icon:"image",color:"#ff9d37",title:I18n.t("显示与个性化"),subtitle:I18n.t("壁纸、应用卡片与屏幕文字"),match:/显示|壁纸|比例|界面|外观|opacity/i},
        {icon:"accessibility_new",color:"#ffb74d",title:I18n.t("无障碍"),subtitle:I18n.t("大字号模式"),match:/适老|大字|无障碍|accessibility|large/i},
        {icon:"verified_user",color:"#85deff",title:I18n.t("锁屏与安全"),subtitle:I18n.t("无操作后自动锁定当前账户"),match:/锁屏|安全|自动锁|超时|lock|timeout|security/i},
        {icon:"shield",color:"#4fd4a4",title:I18n.t("隐私与数据"),subtitle:I18n.t("记录保留期限"),match:/隐私|保留|清理|记录|privacy|retention|cleanup/i},
        {icon:"language",color:"#27b7c5",title:I18n.t("语言 / Language"),subtitle:I18n.t("切换终端界面显示语言"),match:/语言|language|中文|english|英文/i},
        {icon:"volume_up",color:"#10b7a8",title:I18n.t("语音音色"),subtitle:I18n.t("播报音色、输出设备与媒体降音"),match:/语音|音色|播报|voice|tts|speech/i},
        {icon:"schedule",color:"#4c9dff",title:I18n.t("时间与报时"),subtitle:I18n.t("世界时钟校时与整点语音报时"),match:/时间|校时|报时|time|chime|alarm/i},
        {icon:"wifi",color:"#35a9ff",title:I18n.t("网络连接管理"),subtitle:I18n.t("热点、联网总闸与各功能联网"),match:/网络|联网|热点|internet|network|权限|permission|wi.?fi|lan/i},
        {icon:"code",color:"#85deff",title:I18n.t("开发者选项"),subtitle:I18n.t("运行时状态、日志、安全与沙箱"),match:/开发者|调试|沙箱|运行时|developer|debug|sandbox|runtime/i,adminOnly:true,action:"developer"},
        {icon:"info",color:"#4c9dff",title:I18n.t("关于本机"),subtitle:I18n.t("设备信息、版本与软件更新"),match:/关于|本机|版本|硬件|about|device|version|hardware|update/i,hideForGuest:true,action:"about"}
    ]
    property var keyboardAuditInput:null
    property var windowAnimationAuditSnapshot:({})
    property int windowAnimationAuditStage:0
    property int windowAnimationAuditTicks:0
    property string pendingPowerAction:""
    property string lastFileTapKey:""
    property double lastFileTapAt:0
    function recountNotifications() {
        let count=0
        for(let i=0;i<notices.count;++i)if(!notices.get(i).read)++count
        unreadNotifications=count
    }
    function markNotificationsRead() {
        for(let i=0;i<notices.count;++i)notices.setProperty(i,"read",true)
        recountNotifications()
    }
    function activateFileEntry(entry) {
        const key=entry.relative||entry.name
        const now=Date.now()
        if(lastFileTapKey===key && now-lastFileTapAt<450) {openFileRow(entry);lastFileTapKey="";return}
        lastFileTapKey=key;lastFileTapAt=now;fileSelection=key
    }
    function notificationIdentity(message) {
        if(/热点|Wi-?Fi|网络/.test(message))return {app:"Internet",icon:"wifi"}
        if(/蓝牙|Bluetooth/.test(message))return {app:"Bluetooth",icon:"bluetooth"}
        if(/控制桥|PBR1|USB/.test(message))return {app:I18n.t("控制桥"),icon:"lan"}
        if(/模块/.test(message))return {app:I18n.t("模块"),icon:"extension"}
        return {app:I18n.t("模块化终端"),icon:"notifications"}
    }
    function notify(title,message,important,appName,iconName) {
        const identity=notificationIdentity(message)
        const sourceName=appName||identity.app, sourceIcon=iconName||identity.icon
        if(notices.count && notices.get(0).message===message && notices.get(0).title===title)return
        notices.insert(0,{title:title,message:message,appName:sourceName,iconName:sourceIcon,time:Qt.formatTime(new Date(),"hh:mm"),read:devicePanel.opened,important:important})
        while(notices.count>100)notices.remove(notices.count-1)
        recountNotifications()
        bannerTitle=title;bannerMessage=message;bannerAppName=sourceName;bannerIconName=sourceIcon;bannerTime=Qt.formatTime(new Date(),"hh:mm");bannerImportant=important
        notificationBanner.open();bannerTimer.interval=important?10000:5000;bannerTimer.restart()
    }
    property string activeSession: ""
    property string pendingWriteInstance: ""
    // 子页面里的同名 property 会遮蔽外层 id；通过别名显式注入，避免
    // `timeSync: timeSync` 变成自绑定并触发 binding loop。
    readonly property var timeSyncBackend: timeSync
    readonly property var alarmBackend: alarmEngine
    readonly property bool modulePageLoaded: modulePageHost.hasPage
    property bool bridgeConnectedPromptShown: false
    property string moduleMessage: ""
    property var activeActions: []
    property var trustQueue: []
    property var trustItem: ({instance:"", title:"", permissions:[]})
    property string folder: ""
    property string wallpaperFolder:""
    readonly property string localizedLongDate:(new Date()).toLocaleDateString(Qt.locale(systemTools.uiLanguage==="zh"?"zh_CN":"en_US"),systemTools.uiLanguage==="zh"?"yyyy年M月d日 dddd":"dddd, MMMM d, yyyy")
    function textBackground(label) {
        // Efficient profile uses opaque dark cards. Avoid per-label coordinate
        // mapping and wallpaper file checks on every carousel animation frame.
        if(efficientRendering)return Theme.background
        // Read geometry and source bindings so resize, carousel movement and a
        // newly selected wallpaper recalculate the local contrast.
        const revision=systemTools.wallpaper
        const scroll=launcher.contentX
        const point=label.mapToItem(homeWallpaper,label.width/2,label.height/2)
        let base=systemTools.wallpaperColor(point.x,point.y,homeWallpaper.width,homeWallpaper.height)
        let onHome=false,card=false,localBackground=null
        for(let node=label;node;node=node.parent){
            if(localBackground===null){
                if(node.background && node.background.color!==undefined && node.background.color.a>0)localBackground=node.background.color
                else if(node!==label && node.color!==undefined && node.color.a>0)localBackground=node.color
            }
            if(node===homePane)onHome=true
            if(node.objectName==="appTile")card=true
        }
        if(onHome)return localBackground!==null?localBackground:card?Theme.blend(Theme.surface,base,systemTools.launcherOpacity):base
        for(let node=label;node;node=node.parent){
            if(node===appShell)return Theme.blend(Theme.background,base,systemTools.moduleOpacity)
            if(node.background && node.background.color!==undefined && node.background.color.a>0)return node.background.color
            if(node!==label && node.color!==undefined && node.color.a>0)return node.color
        }
        return Theme.background
    }
    function connectionStateLabel(state) {
        return ({attached:I18n.t("检测到模块"),connecting:I18n.t("正在连接"),downloading_package:I18n.t("下载功能包"),
            verifying_package:I18n.t("验证签名"),awaiting_trust:I18n.t("等待权限确认"),loading_plugin:I18n.t("加载界面"),
            ready:I18n.t("已连接"),contact_detached:I18n.t("无线已连接，触点已断开"),data_lost:I18n.t("正在重连"),
            error:I18n.t("连接失败"),disconnecting:I18n.t("正在断开"),unloading:I18n.t("正在卸载"),closed:I18n.t("已断开")})[state] || state
    }
    property var fileRows: []
    property string filePath: ""
    property string fileFilter: ""
    property bool fileGridView: true
    property string fileSelection: ""
    property bool filesRecent:false
    property bool fileSearchVisible:false
    property string fileOperation:""
    property string fileOperationError:""
    readonly property var filteredFileRows:fileRows.filter(function(row){return !fileFilter || row.name.toLowerCase().indexOf(fileFilter.toLowerCase())>=0})
    property var fileHistory: [""]
    property int fileHistoryIndex: 0
    property bool fileEditable: true
    property var browserBookmarks: []
    property var browserHistory: []
    property real browserTouchDragDistance:0
    property var browserDownloads: []
    property var pendingBrowserAuth:null
    property var pendingBrowserPermission:null
    // 任务栏/首页时钟跟随设置里的时间格式（24 小时 / 上午·下午），
    // 每秒由 clockTick 触发重算；切换格式时绑定会立即重算。
    property int clockTick: 0
    property string clockText: {
        clockTick
        const now = new Date()
        if (timeFormat !== "12") return Qt.formatTime(now, "hh:mm")
        return (now.getHours() >= 12 ? I18n.t("下午") : I18n.t("上午")) + " " +
               TimeMath.formatHm12({ hour: now.getHours(), minute: now.getMinutes() })
    }
    property bool browserTestRunning: false
    property bool browserTestPassed: false
    property bool browserTouchLinkPassed:false
    property string browserStatus: ""
    property string browserHttpPending: ""
    property string noteFile: "pi-terminal-note.txt"
    property string noteText: ""
    property string calcDisplay: "0"
    // 表达式（用户按键拼出来的算式，等号后保留 "算式 ="）。
    property string calcExpression: ""
    // 历史：最近 20 条 { expr, result }。
    // 计算器历史：存 calc/history（JSON），重启后仍在。
    property var calcHistory: {
        if (typeof systemTools === "undefined" || !systemTools) return []
        const raw = systemTools.settingsRead("calc/history", "")
        if (raw.length === 0) return []
        try {
            const parsed = JSON.parse(raw)
            return Array.isArray(parsed) ? parsed : []
        } catch (e) { return [] }
    }

    function saveCalcHistory() {
        if (typeof systemTools === "undefined" || !systemTools) return
        systemTools.settingsWrite("calc/history", JSON.stringify(calcHistory))
    }

    function removeCalcHistoryAt(index) {
        const next = []
        for (let i = 0; i < calcHistory.length; ++i) if (i !== index) next.push(calcHistory[i])
        calcHistory = next
        saveCalcHistory()
    }

    function clearCalcHistory() {
        calcHistory = []
        saveCalcHistory()
    }
    property real calcStored: 0
    property string calcOperator: ""
    property bool calcFresh: true
    property string paintColor: "#13283d"
    property real paintSize: 6
    property bool paintEraser: false
    property bool paintRectangle: false
    property var paintStrokes: []
    property var paintRedo: []
    readonly property real paintCanvasWidth:paintCanvas.width
    readonly property real paintCanvasHeight:paintCanvas.height
    readonly property real paintToolbarHeight:paintColumn.height-paintCanvas.parent.height
    function paintAuditSnapshot() {
        const p=paintCanvas.mapToItem(win.contentItem,0,0)
        return JSON.stringify({canvasWidth:paintCanvas.width,canvasHeight:paintCanvas.height,
            canvasX:p.x,canvasY:p.y,toolbarHeight:paintToolbar.height,brushSize:paintSize,
            eraser:paintEraser,rectangle:paintRectangle,color:paintColor,canUndo:paintStrokes.length>0,
            canRedo:paintRedo.length>0,phase:phase,section:section})
    }
    function paintAuditExercise() {
        if(paintCanvas.width<100 || paintCanvas.height<80)return false
        const n=paintStrokes.length
        paintStrokes=paintStrokes.concat([{color:"#d83d58",size:6*uiScale,
            type:"freehand",points:[{x:paintCanvas.width*0.15,y:paintCanvas.height*0.5},{x:paintCanvas.width*0.85,y:paintCanvas.height*0.5}]}])
        paintCanvas.redraw()
        paintUndo();if(paintStrokes.length!==n || paintRedo.length!==1)return false
        paintRedoStroke();if(paintStrokes.length!==n+1 || paintRedo.length!==0)return false
        paintStrokes=paintStrokes.concat([{color:"#3478c6",size:3*uiScale,type:"rectangle",
            points:[{x:paintCanvas.width*0.25,y:paintCanvas.height*0.2},{x:paintCanvas.width*0.6,y:paintCanvas.height*0.8}]}])
        paintCanvas.redraw()
        const rectangleRecorded=paintStrokes[paintStrokes.length-1].type==="rectangle"
        paintUndo();const rectangleUndo=paintStrokes.every(function(s){return s.type!=="rectangle"})
        paintRedoStroke();const rectangleRedo=paintStrokes.some(function(s){return s.type==="rectangle"})
        paintEraser=true;const eraserSelected=paintEraser
        paintEraser=true;paintRectangle=false;paintSize=6;paintCanvas.redraw()
        return rectangleRecorded && rectangleUndo && rectangleRedo && eraserSelected && paintStrokes.length===n+2 && paintCanvas.width>0
    }
    property bool exitPending:false
    readonly property bool permissionPending:trustDialog.visible
    property int browserViewGeneration: 0
    // 浏览器视图在 Loader 里懒创建；未打开过浏览器时这里为 null。
    // StackLayout 没有可靠的 currentItem 暴露，改为按 Repeater 的 index
    // 找到当前标签的 WebEngineView；否则 activeBrowser 会一直停在第一页。
    property var activeBrowser: null
    function refreshActiveBrowser() {
        const layout=browserViewLoader.item
        if(!layout){activeBrowser=null;return}
        let fallback=null
        for(let i=0;i<layout.children.length;++i){
            const view=layout.children[i]
            if(!view || view.index===undefined) continue
            if(!fallback) fallback=view
            if(view.index===browserTabs.currentIndex){activeBrowser=view;return}
        }
        activeBrowser=fallback
    }
    property bool browserWheelEnabled: false
    readonly property string defaultBrowserUrl: "https://baidu.com"
    Timer { interval: 1000; running: true; repeat: true; onTriggered: win.clockTick++ }
    function builtin(page) {
        const entry = ({1:{entryId:"connections",title:I18n.t("连接管理"),iconName:"lan",accentColor:"#ad8cff",route:1,instance:"",ready:true},
                 2:{entryId:"browser",title:I18n.t("浏览器"),iconName:"language",accentColor:"#4fd4a4",route:2,instance:"",ready:true},
                 3:{entryId:"files",title:I18n.t("文件"),iconName:"folder",accentColor:"#ffbd54",route:3,instance:"",ready:true},
                 4:{entryId:"settings",title:I18n.t("设置"),iconName:"settings",accentColor:"#4c9dff",route:4,instance:"",ready:true},
                 6:{entryId:"calculator",title:I18n.t("计算器"),iconName:"apps",accentColor:"#ff9d37",route:6,instance:"",ready:true},
                 7:{entryId:"paint",title:I18n.t("画图"),iconName:"image",accentColor:"#ff6584",route:7,instance:"",ready:true},
                 8:{entryId:"notes",title:I18n.t("文本便笺"),iconName:"text_snippet",accentColor:"#36c8db",route:8,instance:"",ready:true},
                 9:{entryId:"music",title:I18n.t("音乐播放器"),iconName:"volume_up",accentColor:"#d889e8",route:9,instance:"",ready:true},
                 10:{entryId:"video",title:I18n.t("视频播放器"),iconName:"play_arrow",accentColor:"#65c9bd",route:10,instance:"",ready:true},
                 11:{entryId:"tv",title:I18n.t("网络电视"),iconName:"tv",accentColor:"#ff7a59",route:11,instance:"",ready:true},
                 12:{entryId:"time",title:I18n.t("时间"),iconName:"schedule",accentColor:"#8f7bff",route:12,instance:"",ready:true},
                 13:{entryId:"voice",title:I18n.t("语音音色"),iconName:"volume_up",accentColor:"#10b7a8",route:13,instance:"",ready:true},
                 14:{entryId:"weather",title:I18n.t("天气"),iconName:"wb_cloudy",accentColor:"#35a9ff",route:14,instance:"",ready:true},
                 15:{entryId:"users",title:I18n.t("用户与权限"),iconName:"person_add",accentColor:"#8f7bff",route:15,instance:"",ready:true}})[page]
        // 临时会话的权限边界：设置、连接管理、用户与权限仍然出现在主界面，
        // 但灰显、点开只弹"无权限"。灰显只是第一层，真正的拒绝在
        // SessionManager/securityService 里（隐藏入口从来不是安全边界）。
        // restricted 必须始终存在：ListModel 的角色在首次插入时定型，
        // 只在访客分支才带这个键会让登录后残留 true（实测灰卡不消退）。
        if (!entry) return entry
        const guest = typeof sessionManager !== "undefined" && sessionManager && sessionManager.guestSession
        const restricted = !!guest && (page === 3 || page === 4 || page === 15)
        return ({entryId:entry.entryId, title:entry.title, iconName:entry.iconName,
                 accentColor:entry.accentColor, route:entry.route, instance:entry.instance,
                 ready:entry.ready, restricted:restricted})
    }
    function rememberApp(entry) {
        for(let i=recentApps.count-1;i>=0;--i)if(recentApps.get(i).entryId===entry.entryId)recentApps.remove(i)
        recentApps.insert(0,{entryId:entry.entryId,title:entry.title,iconName:entry.iconName,accentColor:entry.accentColor,route:entry.route,instance:entry.instance})
        while(recentApps.count>3)recentApps.remove(recentApps.count-1)
    }
    function removeRecent(entryId) {
        for(let i=recentApps.count-1;i>=0;--i) if(recentApps.get(i).entryId===entryId) recentApps.remove(i)
    }
    function clearForegroundModulePage() {
        if (activeSession !== "") {
            closeModulePopups()
            modulePageHost.unload(); activeSession=""; activeActions=[]; moduleMessage=""
        }
    }
    function closePopupsUnder(root) {
        if (!root) return
        const seen=[]
        function visit(object) {
            if (!object || seen.indexOf(object)>=0) return
            seen.push(object)
            for(let name of ["children","data","resources"]) {
                const list=object[name]
                if (list && typeof list.length==="number")
                    for(let n=0;n<list.length;++n) visit(list[n])
            }
            if (object!==root && object.opened!==undefined && typeof object.close==="function") object.close()
        }
        visit(root)
    }
    function closeModulePopups() { closePopupsUnder(modulePageHost.page) }
    // 二级页是 appShell 的常驻子项；关闭/切换/最小化应用时必须清掉它们的
    // open 状态，否则联网权限、关于本机这类页面会直接盖到下一个应用上。
    function closeAuxiliaryPanels(immediate) {
        win.aboutDeviceOpen=false
        win.networkPermissionsOpen=false
        win.connectionSettingsOpen=false
        win.developerPanelOpen=false
        win.testModeOpen=false
        if (!immediate) return
        closePopupsUnder(settingsPageLoader.item)
        closePopupsUnder(aboutDevicePage)
        closePopupsUnder(networkPermissionsPageLoader.item)
        closePopupsUnder(connectionSettingsPage)
        closePopupsUnder(developerPanel)
        closePopupsUnder(testModePanel)
        if (aboutDevicePage) aboutDevicePage.hideImmediately()
        if (networkPermissionsPageLoader.item) networkPermissionsPageLoader.item.hideImmediately()
        if (connectionSettingsPage) connectionSettingsPage.hideImmediately()
        if (developerPanel) developerPanel.hideImmediately()
        if (testModePanel) testModePanel.hideImmediately()
    }
    // 把 root 策略里的第三方模块授权同步到当前实例。
    function applyModulePermissions() {
        if (typeof networkPolicy === "undefined" || !networkPolicy) return
        const cards = connectionManager.cards
        for (let i = 0; i < cards.length; ++i) {
            const card = cards[i]
            if (!card || !card.instance) continue
            const id = String(card.packageId || "")
            if (id === "") continue
            const broker = String(card.networkApi || "none") === "broker"
            const files = String(card.fileApi || "none") === "home-read"
            networkGate.setModuleNetworkAllowed(card.instance,
                broker && networkPolicy.moduleNetworkEnabled(id))
            networkGate.setModuleFileAllowed(card.instance,
                files && networkPolicy.moduleFileEnabled(id))
        }
    }
    function announce(text) { if(systemTools.speechEnabled) systemTools.speak(text) }
    // 指定音色播报（后续功能用）；同样受总开关/300 字/降音约束。
    function announceWithVoice(text, voiceId) { if(systemTools.speechEnabled) systemTools.speakWithVoice(text, voiceId) }
    function refreshFiles() {
        if(filesRecent){fileRows=systemTools.recentFiles();return}
        fileRows=systemTools.files(folder).sort(function(a,b) {
            if (a.directory!==b.directory) return a.directory ? -1 : 1
            return a.name.localeCompare(b.name)
        })
    }
    function filePreviewRows() {
        return filteredFileRows.filter(function(e) { return !e.directory && /\.(png|jpe?g|bmp|gif|webp)$/i.test(e.name) }).map(function(e) {
            return Object.assign({}, e, {relative:e.relative || ((folder ? folder + "/" : "") + e.name)})
        })
    }
    function navigateFiles(next,record) {
        next=next || ""
        if (next===folder && !filesRecent) { refreshFiles(); return }
        folder=next; filesRecent=false; fileSelection=""; fileFilter=""; refreshFiles()
        if (record!==false) { fileHistory=fileHistory.slice(0,fileHistoryIndex+1); fileHistory.push(folder); fileHistoryIndex=fileHistory.length-1 }
    }
    function fileParent() {
        if(/^@usb\/[^/]+\/?$/.test(folder))return ""
        if (!folder) return ""
        return folder.substring(0,Math.max(0,folder.lastIndexOf('/')))
    }
    function openFileRow(row) {
        fileSelection=row.relative || row.name
        let p=row.relative || ((folder?folder+"/":"")+row.name)
        if(row.directory) { navigateFiles(p) }
        else {
            systemTools.rememberFile(p)
            if (/\.(png|jpe?g|bmp|gif|webp)$/i.test(p)) {
                const images = fileRows.filter(function(e) { return !e.directory && /\.(png|jpe?g|bmp|gif|webp)$/i.test(e.name) }).map(function(e) { return Object.assign({}, e, {relative:e.relative || ((folder ? folder + "/" : "") + e.name)}) })
                pictureViewer.showImages(images, images.findIndex(function(e) { return e.relative === p }))
            } else if (/\.(mp3|flac|m4a|aac|ogg|opus|wav|aiff|ape|wma)$/i.test(p)) {
                auditPage(9)
                const music = findControl(win.contentItem,"musicPlayerPage")
                music.autoNetworkMode = false; music.mode = "offline"
                music.folder = p.substring(0, Math.max(0,p.lastIndexOf('/'))); music.refresh()
                const track = music.entries.find(function(e) { return e.relative === p })
                if(track) music.playFromEntry(track)
            } else if (/\.(mp4|mkv|avi|mov|webm|m4v|mpeg|mpg)$/i.test(p)) {
                auditPage(10); findControl(win.contentItem,"videoPlayerPage").playFile(p,row.name)
            } else { filePath=p; fileEditable=systemTools.editable(p); viewer.text=systemTools.read(p); fileDialog.open() }
        }
    }
    function requestFileOperation(operation) {
        fileOperation=operation;fileOperationError=""
        const selected=fileRows.find(function(row){return (row.relative || row.name)===fileSelection})
        operationName.text=operation==="rename" && selected?selected.name:""
        fileOperationDialog.open()
    }
    function completeFileOperation() {
        const name=operationName.text.trim()
        if(fileOperation!=="delete" && (!name || name==="." || name===".." || name.indexOf("/")>=0)) {fileOperationError=I18n.t("请输入有效名称");return}
        const selected=fileRows.find(function(row){return (row.relative || row.name)===fileSelection})
        if((fileOperation==="rename" || fileOperation==="delete") && !selected){fileOperationError=I18n.t("请先选择文件或文件夹");return}
        const source=selected && selected.relative ? selected.relative : ((folder?folder+"/":"")+fileSelection)
        const target=(folder?folder+"/":"")+name
        let ok=false
        if(fileOperation==="newFile")ok=systemTools.createFile(target,"")
        else if(fileOperation==="newFolder")ok=systemTools.makeDirectory(target)
        else if(fileOperation==="rename")ok=systemTools.rename(source,target)
        else if(fileOperation==="delete")ok=systemTools.remove(source)
        if(!ok){fileOperationError=I18n.t("操作失败：请检查名称、权限或目录是否为空");return}
        fileSelection="";refreshFiles();fileOperationDialog.close()
    }
    function fileIcon(row) {
        if (row.directory) return "folder"
        const name=row.name.toLowerCase()
        if (/\.(png|jpe?g|gif|bmp|webp|svg)$/.test(name)) return "image"
        if (/\.(c|cc|cpp|h|hpp|qml|js|py|sh|rs|java|json|xml|html|css)$/.test(name)) return "code"
        if (/\.(zip|tar|gz|bz2|xz|7z|rar|zst)$/.test(name)) return "archive"
        if (/\.(txt|md|csv|log|ini|conf|yaml|yml)$/.test(name)) return "text_snippet"
        return "text_snippet"
    }
    function activateWallpaperEntry(row) {
        const relative=(wallpaperFolder?wallpaperFolder+"/":"")+row.name
        if(row.directory)wallpaperFolder=relative
        else if(systemTools.setFileWallpaper(relative))wallpaperPicker.close()
    }
    function loadNote() {
        const text=systemTools.read(noteFile)
        noteText=text==="无法读取"||text===I18n.t("无法读取")?"":text
    }
    function saveNote(path) {
        const target=path||noteFile
        const rich=/\.html?$/i.test(target)
        if(systemTools.write(target,documentFormatter.serialize(noteEditor.textDocument,rich))) {noteFile=target;notesStatus.text=I18n.t("便笺已保存");announce(I18n.t("便笺已保存"));return true}
        else notesStatus.text=I18n.t("保存失败：请检查写入权限、文件路径及 64 KiB 文本大小限制。")
        return false
    }
    function paintUndo() {
        if(!paintStrokes.length)return
        paintRedo=paintRedo.concat([paintStrokes[paintStrokes.length-1]])
        paintStrokes=paintStrokes.slice(0,paintStrokes.length-1);paintCanvas.redraw()
    }
    function paintRedoStroke() {
        if(!paintRedo.length)return
        paintStrokes=paintStrokes.concat([paintRedo[paintRedo.length-1]])
        paintRedo=paintRedo.slice(0,paintRedo.length-1);paintCanvas.redraw()
    }
    function paintClear() {paintStrokes=[];paintRedo=[];paintCanvas.redraw()}
    function calcReset() {calcDisplay="0";calcExpression="";calcStored=0;calcOperator="";calcFresh=true}
    function calcBackspace() {
        if(calcExpression.length===0){calcDisplay="0";calcFresh=true;return}
        calcExpression=calcExpression.slice(0,calcExpression.length-1)
        calcDisplay=calcExpression.length>0?calcExpression:"0"
        calcFresh=calcExpression.length===0
    }
    // 表达式求值：递归下降，支持 + - × ÷ % 括号与负号。
    function calcEvaluate(text) {
        const src=String(text||"")
                  .replace(/×/g,"*").replace(/÷/g,"/").replace(/−/g,"-")
                  .replace(/%/g,"/100")
        let i=0
        function skip(){while(i<src.length&&src.charAt(i)===" ")i++}
        function number(){
            skip();let start=i
            while(i<src.length&&/[0-9.]/.test(src.charAt(i)))i++
            if(start===i)throw "num"
            return parseFloat(src.slice(start,i))
        }
        function primary(){
            skip()
            const ch=src.charAt(i)
            if(ch==="("){i++;const v=expr();skip();if(src.charAt(i)===")")i++;return v}
            if(ch==="-"){i++;return -primary()}
            if(ch==="+"){i++;return primary()}
            return number()
        }
        function term(){
            let v=primary();skip()
            while(i<src.length&&(src.charAt(i)==="*"||src.charAt(i)==="/")){
                const op=src.charAt(i++);const r=primary()
                v=op==="*"?v*r:(r===0?NaN:v/r);skip()
            }
            return v
        }
        function expr(){
            let v=term();skip()
            while(i<src.length&&(src.charAt(i)==="+"||src.charAt(i)==="-")){
                const op=src.charAt(i++);const r=term()
                v=op==="+"?v+r:v-r;skip()
            }
            return v
        }
        try{return expr()}catch(e){return NaN}
    }
    function calcTailNumber() {
        const m=calcExpression.match(/(\d+\.?\d*)$/)
        return m?m[0]:""
    }
    // 一元函数（√ x² 1/x sin cos）：只作用于表达式末尾的那个数。
    function calcApplyUnary(kind) {
        const tail=calcTailNumber()
        const value=tail===""?0:parseFloat(tail)
        let out=0
        if(kind==="√")out=value<0?NaN:Math.sqrt(value)
        else if(kind==="x²")out=value*value
        else if(kind==="1/x")out=value===0?NaN:1/value
        else if(kind==="sin")out=Math.sin(value*Math.PI/180)
        else if(kind==="cos")out=Math.cos(value*Math.PI/180)
        const text=isNaN(out)?"0":String(Math.round(out*10000000000)/10000000000)
        if(tail==="")calcExpression+=text
        else calcExpression=calcExpression.slice(0,calcExpression.length-tail.length)+text
        calcDisplay=calcExpression
        calcFresh=false
    }
    function calcInput(value) {
        if(value==="AC"||value==="C"){calcReset();return}
        if(value==="⌫"){calcBackspace();return}
        if(value==="π"){calcExpression+=String(Math.PI);calcDisplay=calcExpression;calcFresh=false;return}
        if(value==="=") {calcEquals();return}
        if(value==="+"||value==="-"||value==="×"||value==="÷") {
            if(calcExpression.length===0)calcExpression="0"
            const last=calcExpression.charAt(calcExpression.length-1)
            if(["+","-","×","÷"].indexOf(last)>=0)
                calcExpression=calcExpression.slice(0,calcExpression.length-1)
            calcExpression+=value
            calcDisplay=calcExpression
            calcFresh=false
            return
        }
        if(value===".") {
            const tail=calcTailNumber()
            if(tail.indexOf(".")>=0)return
            calcExpression+=tail===""?"0.":"."
            calcDisplay=calcExpression
            calcFresh=false
            return
        }
        if(value==="±") {
            const tail=calcTailNumber()
            if(tail==="")return
            const pos=calcExpression.length-tail.length
            const before=calcExpression.slice(0,pos)
            calcExpression=(before.endsWith("-")?before.slice(0,before.length-1)+tail:before+"-"+tail)
            calcDisplay=calcExpression
            return
        }
        if(value==="√"||value==="x²"||value==="1/x"||value==="sin"||value==="cos") {
            calcApplyUnary(value);return
        }
        // 数字、括号
        calcExpression+=value
        calcDisplay=calcExpression
        calcFresh=false
    }
    function calcEquals() {
        if(calcExpression.length===0)return
        const result=calcEvaluate(calcExpression)
        const shown=isNaN(result)?"错误":String(Math.round(result*100000000)/100000000)
        calcHistory=([{expr:calcExpression+" =",result:shown}].concat(calcHistory)).slice(0,20)
        saveCalcHistory()
        calcExpression=shown==="错误"?calcExpression:calcExpression+" ="
        calcDisplay=shown
        calcFresh=true
    }
    function taskRow(entryId) {
        for(let i=0;i<openTasks.count;++i) if(openTasks.get(i).entryId===entryId) return openTasks.get(i)
        return null
    }
    function updateTaskState() {
        for(let i=0;i<openTasks.count;++i) if(openTasks.get(i).entryId===appEntryId) {
            openTasks.setProperty(i,"minimized",appMinimized)
            openTasks.setProperty(i,"maximized",appMaximized)
            return
        }
    }
    function registerTask(entry) {
        let previous=taskRow(entry.entryId)
        let row={entryId:entry.entryId,title:entry.title,iconName:entry.iconName||"extension",accentColor:entry.accentColor||Theme.accent,route:entry.route,instance:entry.instance||"",ready:true,minimized:previous?previous.minimized:false,maximized:previous?previous.maximized:entry.route===2}
        for(let i=0;i<openTasks.count;++i)if(openTasks.get(i).entryId===entry.entryId){openTasks.set(i,row);return}
        openTasks.append(row)
    }
    // 访客受限入口：只以内置应用、且非模块会话为准。
    // 抽屉/最近使用/快捷键构造的 entry 可能没有 restricted 字段，
    // 所以这里按 route 再判一次，不能只依赖卡片上的灰显状态。
    function guestRestricted(entry) {
        if (!entry || entry.instance || !sessionManager.guestSession) return false
        return entry.restricted === true || entry.route === 3
                || entry.route === 4 || entry.route === 15
    }
    function openVoiceSettings() {
        // 语音音色已从主界面移入设置：从这里进入同一个二级页面（route 13）。
        launch(builtin(13), width / 2, contentItem.height / 2)
    }
    function launch(entry,x,y) {
        if(!entry)return false
        if (guestRestricted(entry)) { restrictedNotice.show(entry.title); return false }
        if (appMinimized && appEntryId===entry.entryId) {
            restoreApp();return true
        }
        if(phase!=="home") {
            if(appEntryId===entry.entryId){appMinimized=false;phase="open";updateTaskState();return true}
            pendingLaunch={entry:entry,x:x,y:y};switchTask(entry);return true
        }
        // 新应用从干净的应用壳开始：不继承上一个应用打开的二级页。
        closeAuxiliaryPanels(true)
        if(!entry.instance) clearForegroundModulePage()
        if(entry.instance) {
            let session=null
            for(let card of connectionManager.cards)if(card.instance===entry.instance)session=card
            if(!session || !session.ready){showDevicePanel(false);return false}
            activeSession=entry.instance;activeActions=session.actions;moduleMessage=session.message
            // §0.7：模块页在独立引擎里加载，只注入 sessionModel 与只读 userContext。
            applyModulePermissions()
            modulePageHost.setNetworkInstance(entry.instance)
            modulePageHost.setPackageId(connectionManager.modulePackageId(entry.instance))
            modulePageHost.load(Qt.url(connectionManager.pageProvider.page(entry.instance)),
                                connectionManager.pageProvider.model(entry.instance),
                                {background:Theme.background, surface:Theme.surface,
                                 foreground:Theme.foreground, accent:Theme.accent,
                                 scale:win.uiScale})
        }
        section=entry.route;appTitle=entry.title;appIcon=entry.iconName;appEntryId=entry.entryId
        if(section===3)refreshFiles()
        if(section===8)loadNote()
        if(section===6)calcReset()
        registerTask(entry)
        let saved=taskRow(entry.entryId);appMinimized=false;appMaximized=saved?saved.maximized:entry.route===2
        updateTaskState()
        originX=Math.max(0,Math.min(width,x===undefined?width/2:x));originY=Math.max(0,Math.min(contentItem.height,y===undefined?contentItem.height/2:y))
        rememberApp(entry);openProgress=0;phase="opening";zoomAnimation.to=1;zoomAnimation.duration=260;zoomAnimation.easing.type=Easing.OutCubic;zoomAnimation.restart()
        if(openTaskIds.indexOf(entry.entryId)<0)openTaskIds.push(entry.entryId)
        return true
    }
    function go(page) {if(page===0)closeApp();else launch(builtin(page),width/2,contentItem.height/2)}
    function browserPermissionName(feature) {
        if(feature===WebEngineView.Geolocation)return I18n.t("访问位置")
        if(feature===WebEngineView.MediaAudioCapture)return I18n.t("访问麦克风")
        if(feature===WebEngineView.MediaVideoCapture)return I18n.t("访问摄像头")
        if(feature===WebEngineView.MediaAudioVideoCapture)return I18n.t("访问麦克风和摄像头")
        if(feature===WebEngineView.DesktopVideoCapture)return I18n.t("捕获屏幕画面")
        if(feature===WebEngineView.DesktopAudioVideoCapture)return I18n.t("捕获屏幕画面和声音")
        if(feature===WebEngineView.Notifications)return I18n.t("发送通知")
        return I18n.t("未知权限")
    }
    function resolveBrowserPermission(granted) {
        if(pendingBrowserPermission)pendingBrowserPermission.view.grantFeaturePermission(pendingBrowserPermission.origin,pendingBrowserPermission.feature,granted)
        pendingBrowserPermission=null;browserPermissionDialog.close()
    }
    function closeApp() {
        if(phase==="home" || phase==="closing")return
        closeAuxiliaryPanels(true)
        // 关闭 = 彻底停止：电视立即停播并释放解码器，不靠 active 变化兜底。
        if(section===11) tvPage.stopPlayback()
        if(section===2){const savedTabs=[];for(let i=0;i<tabs.count;++i)savedTabs.push({address:tabs.get(i).address,pageTitle:tabs.get(i).pageTitle,privateMode:tabs.get(i).privateMode});viperBrowser.saveSession(savedTabs,browserTabs.currentIndex)}
        zoomAnimation.stop();phase="closing";zoomAnimation.to=0;zoomAnimation.duration=200;zoomAnimation.easing.type=Easing.InCubic;zoomAnimation.restart()
    }
    function minimizeApp() {
        if(phase!=="open") return
        closeAuxiliaryPanels(true)
        // 电视最小化按“后台播放”处理：保留管线，音频继续。
        if(section===11) tvPage.enterBackgroundPlayback()
        closeModulePopups()
        appMinimizeAnimating=true;phase="minimizing"
        minimizeAnimation.from=openProgress;minimizeAnimation.to=0.06;minimizeAnimation.restart()
        announce(I18n.t("最小化应用"))
    }
    function finishMinimizeAnimation() {
        if(phase!=="minimizing")return
        appMinimized=true;appMinimizeAnimating=false;phase="home";modulePageHost.unload();updateTaskState()
        let releases=releaseQueue;releaseQueue=[];Qt.callLater(function(){for(let instance of releases)connectionManager.releasePage(instance)})
    }
    function restoreApp() {
        minimizeAnimation.stop()
        restoreAnimation.stop()
        appMinimized=false
        if(activeSession!=="") {
            const page=connectionManager.pageProvider.page(activeSession)
            const model=connectionManager.pageProvider.model(activeSession)
            if(page!=="" && model) {
                applyModulePermissions()
                modulePageHost.setNetworkInstance(activeSession)
                modulePageHost.setPackageId(connectionManager.modulePackageId(activeSession))
                modulePageHost.load(Qt.url(page), model,
                {background:Theme.background, surface:Theme.surface,
                 foreground:Theme.foreground, accent:Theme.accent, scale:win.uiScale})
            }
            else { activeSession="";activeActions=[];moduleMessage="";section=0;phase="home";updateTaskState();return }
        }
        appMinimizeAnimating=true;phase="restoring";updateTaskState()
        restoreAnimation.from=Math.max(0.06,openProgress);restoreAnimation.to=1;restoreAnimation.restart()
    }
    function finishRestoreAnimation() {
        if(phase!=="restoring")return
        phase="open";appMinimizeAnimating=false;openProgress=1;updateTaskState()
    }
    function toggleMaximize() { if(phase!=="open") return;appMaximized=!appMaximized;updateTaskState() }
    function switchTask(entry) {
        const existing=taskRow(entry.entryId)
        if (existing && appEntryId===entry.entryId) {
            if (appMinimized || phase!=="open") { existing.minimized=false; restoreApp() }
            else { minimizeApp() }
            return
        }
        for(let i=0;i<openTasks.count;++i)if(openTasks.get(i).entryId===entry.entryId){
            // Keep task records alive while changing the foreground view; do not
            // send the current module through the close/unload path.
            pendingLaunch=null;closeAuxiliaryPanels(true);clearForegroundModulePage();announce(I18n.t("切换到")+entry.title);
            // 任务栏切换不是关闭：电视按后台播放处理，保住管线与音频。
            if(section===11) tvPage.enterBackgroundPlayback()
            phase="home";
            openTasks.setProperty(i,"minimized",false)
            Qt.callLater(function(){launch(entry,width/2,contentItem.height/2)});return
        }
        if(openTaskIds.indexOf(entry.entryId)<0)openTaskIds.push(entry.entryId)
        pendingLaunch={entry:entry,x:width/2,y:contentItem.height/2};
        closeAuxiliaryPanels(true)
        clearForegroundModulePage();
        if(section===11) tvPage.enterBackgroundPlayback()
        phase="home";Qt.callLater(function(){let next=pendingLaunch;pendingLaunch=null;launch(next.entry,next.x,next.y)})
    }
    function arrangeWindows() { }
    function exitApplication() {
        if(phase==="home"){ Qt.quit(); return }
        exitPending=true; announce(I18n.t("正在退出")); closeApp()
    }
    function finishTransition() {
        if(phase==="opening"){phase="open";return}
        if(phase!=="closing")return
        closeAuxiliaryPanels(true)
        modulePageHost.unload();activeSession="";activeActions=[];moduleMessage="";section=0;phase="home";appMinimized=false;appMaximized=false
        const closingId=appEntryId;openTaskIds=openTaskIds.filter(function(id){return id!==closingId})
        for(let i=openTasks.count-1;i>=0;--i)if(openTasks.get(i).entryId===closingId)openTasks.remove(i)
        removeRecent(appEntryId);appEntryId=""
        let releases=releaseQueue;releaseQueue=[]
        Qt.callLater(function(){for(let instance of releases)connectionManager.releasePage(instance)})
        if(pendingLaunch){let next=pendingLaunch;pendingLaunch=null;Qt.callLater(function(){launch(next.entry,next.x,next.y)})}
        if(exitPending) Qt.quit()
    }
    function showDevicePanel(notifications) {
        // Status is already maintained by the 5s poll and device/action events.
        // Do not synchronously fan out every SystemTools binding on the first
        // animation frame just to redisplay the same cached values.
        devicePanel.jumpToNotifications=notifications;devicePanel.open();if(notifications)unreadNotifications=0
    }
    function openAppDrawer() { appDrawer.open() }
    function appDrawerAuditSnapshot() { return appDrawer.auditSnapshot() }
    NumberAnimation {id:zoomAnimation;target:win;property:"openProgress";onFinished:win.finishTransition()}
    NumberAnimation {id:minimizeAnimation;target:win;property:"openProgress";duration:300;easing.type:Easing.InCubic;onFinished:win.finishMinimizeAnimation()}
    NumberAnimation {id:restoreAnimation;target:win;property:"openProgress";duration:360;easing.type:Easing.OutCubic;onFinished:win.finishRestoreAnimation()}
    Shortcut {sequence:"Escape";enabled:phase==="open" && !videoFullscreen && !developerPanelOpen && !testModeOpen && !aboutDeviceOpen && !networkPermissionsOpen && !trustDialog.opened && !fileDialog.opened && !fileOperationDialog.opened && !bookmarkDialog.opened && !devicePanel.opened;onActivated:closeApp()}
    function stateText(state) { return connectionStateLabel(state) }
    // 应用卡片的默认顺序（内置应用）；编辑模式确认后会以 layout/apps 覆盖。
    readonly property var appDefaultRoutes: [2,3,1,4,6,7,8,9,10,12,15,14,11]
    readonly property var appDefaultOrder: {
        const ids = []
        for (let route of appDefaultRoutes) ids.push(builtin(route).entryId)
        return ids
    }

    function syncCards() {
        const modules=[]
        for(let card of connectionManager.cards) modules.push({entryId:card.instance,title:card.title,
            description:stateText(card.state),category:I18n.t("模块"),accentColor:"#85deff",iconName:card.icon||"extension",route:5,instance:card.instance,ready:card.ready,restricted:false})
        const apps=[]
        for(let route of appDefaultRoutes) {let app=builtin(route);app.description="";app.category=I18n.t("应用");apps.push(app)}
        // 已保存顺序只认内置应用；新版本新增的应用没有记录，按默认顺序接在末尾。
        let savedOrder=[]
        try { savedOrder=JSON.parse(systemTools.settingsRead("layout/apps","[]")) } catch(e) { savedOrder=[] }
        if (Array.isArray(savedOrder) && savedOrder.length>0) {
            const rank={}
            for(let i=0;i<savedOrder.length;++i) rank[savedOrder[i]]=i
            apps.sort(function(a,b) {
                const ra=rank.hasOwnProperty(a.entryId)?rank[a.entryId]:Number.MAX_SAFE_INTEGER
                const rb=rank.hasOwnProperty(b.entryId)?rank[b.entryId]:Number.MAX_SAFE_INTEGER
                return ra-rb
            })
        }
        const entries=modules.concat(apps)
        for (let i=homeCards.count-1; i>=0; --i)
            if (!entries.some(function(e) { return e.entryId === homeCards.get(i).entryId })) homeCards.remove(i)
        for (let desired=0;desired<entries.length;++desired) {
            let entry=entries[desired]
            let found = -1
            for (let i=0; i<homeCards.count; ++i) if (homeCards.get(i).entryId === entry.entryId) { found=i; break }
            if(found<0)homeCards.insert(desired,entry)
            else {if(found!==desired)homeCards.move(found,desired,1);homeCards.set(desired,entry)}
        }
        for(let i=recentApps.count-1;i>=0;--i)if(recentApps.get(i).instance && !entries.some(function(e){return e.entryId===recentApps.get(i).entryId}))recentApps.remove(i)
        homeRevision++
    }
    function showNextTrust() {
        if (!trustDialog.visible && trustQueue.length) { trustItem=trustQueue.shift(); trustDialog.open() }
    }
    function approveTrustOnce() {
        if (!trustDialog.opened) return
        connectionManager.trust(trustItem.instance,false); trustDialog.close()
    }
    function openVoicePage() {
        launch(builtin(13), width/2, contentItem.height/2)
    }
    // 语音播报的输出设备/测试音色确认浮层仍挂在 Main（Overlay 全局层），
    // 由「语音音色」页通过 hostWindow 调用；设置页不再持有语音播报配置。
    function openAudioOutputPopup() {
        audioOutputPopup.open()
    }
    function openVoiceTestConfirm() {
        voiceTestConfirm.open()
    }
    function openAlarms() {
        launch(builtin(12), width/2, contentItem.height/2)
        Qt.callLater(function() { if (timePage) timePage.setTab(3) })
    }
    function openModule(instance) {
        for (let row of connectionManager.cards) if (row.instance === instance && row.ready) {
            return launch({entryId:instance,title:row.title,iconName:row.icon||"extension",accentColor:"#85deff",route:5,instance:instance,ready:true},width/2,contentItem.height/2)
        }
        showDevicePanel(false);return false
    }
    function loadBrowserAddress(address) {
        if(browserTabs.currentIndex>=0 && browserTabs.currentIndex<tabs.count)tabs.setProperty(browserTabs.currentIndex,"address",address)
        location.text=address
        if(activeBrowser){browserStatus=I18n.t("正在加载");activeBrowser.forceActiveFocus();activeBrowser.url=address}
    }
    function navigateBrowser(text) {
        let address=viperBrowser.resolveAddress(text)
        if (address === "") return
        // 内置浏览器保留 HTTP 可用性，但每次地址栏/历史导航先明确警告。
        if (address.toLowerCase().startsWith("http://")) {
            win.browserHttpPending=address
            browserHttpConfirm.open()
            return
        }
        win.loadBrowserAddress(address)
    }
    function beginBrowserTest() {
        go(2); browserLoaded=true
        tabs.append({address:"about:blank",privateMode:false}); browserTabs.currentIndex=tabs.count-1
        // WebEngineView 是懒加载的；activeBrowser 在下一轮布局后才存在。
        // 不能在 callLater 第一帧就 loadHtml，否则审计会报 loadHtml undefined。
        const start=function(attempt) {
            const view=activeBrowser ? activeBrowser : findControl(win.contentItem,"browserWebView")
            if (!view) {
                if (attempt<60) Qt.callLater(function(){ start(attempt+1) })
                return
            }
            browserTestRunning=true
            view.zoomFactor=1.6
            view.loadHtml("<html><head><title>Local terminal test</title></head><body><h1>Browser ready</h1></body></html>")
        }
        Qt.callLater(function(){ start(0) })
    }
    property bool auditGateWasEnabled: true
    property bool auditBrowserWasAllowed: false
    function auditEnableBrowserFixture() {
        if(typeof networkGate==="undefined")return
        auditGateWasEnabled=networkGate.enabled
        auditBrowserWasAllowed=networkGate.browserAllowed
        if(!networkGate.enabled)networkGate.setEnabledFromUi(true)
        if(!networkGate.browserAllowed)networkGate.setFeatureEnabledFromUi("browser",true)
    }
    function auditRestoreBrowserFixture() {
        if(typeof networkGate==="undefined")return
        networkGate.setFeatureEnabledFromUi("browser",auditBrowserWasAllowed)
        networkGate.setEnabledFromUi(auditGateWasEnabled)
    }
    function auditBrowserTouchPage() {
        tabs.append({address:"about:blank",privateMode:false});browserTabs.currentIndex=tabs.count-1
        viperBrowser.setJavascriptPopupsEnabled(true)
        const start=function(attempt) {
            win.refreshActiveBrowser()
            const view=win.activeBrowser
            if (!view || view.index!==browserTabs.currentIndex) {
                if (attempt<60) Qt.callLater(function(){ start(attempt+1) })
                return
            }
            view.loadHtml("<html><body style='font-size:32px'><a id='go' target='_blank' href='https://touch-link.example/'>TOUCH LINK</a><div style='height:1800px'>TOUCH SCROLL TARGET</div></body></html>")
        }
        Qt.callLater(function(){ start(0) })
    }
    function auditBrowserClickLink() { if(activeBrowser) activeBrowser.runJavaScript("document.getElementById('go').click()") }
    function auditBrowserTouchReset() { if(activeBrowser) activeBrowser.runJavaScript("window.scrollTo(0,0)") }
    function auditBrowserTabCount() { return tabs.count }
    function auditBrowserTabAddress() {
        if (tabs.count<2) tabs.append({address:"about:blank",privateMode:false})
        tabs.setProperty(0,"address","https://first.example")
        tabs.setProperty(1,"address","https://second.example")
        browserTabs.currentIndex=0; browserTabs.currentIndex=1
        return location.text==="https://second.example"
    }
    function auditViperBrowserIntegration() {
        const url="https://viper-bookmark-audit.invalid/"
        const before=viperBrowser.bookmarks().length
        const added=viperBrowser.addBookmark(url,"Viper bridge audit")
        const visible=viperBrowser.bookmarks().some(function(item){return item.url===url&&item.title==="Viper bridge audit"})
        const removed=viperBrowser.removeBookmark(url)
        return JSON.stringify({profile:terminalViperProfile.storageName,
            homePage:viperBrowser.preferences.homePage,
            profileAttached:viperBrowser.attachProfile(terminalViperProfile),
            filtering:viperBrowser.requestFilteringReady(),schemes:viperBrowser.customSchemesReady(),
            javascript:viperBrowser.javascriptEnabled(),images:viperBrowser.imagesEnabled(),
            added:added,visible:visible,removed:removed,count:viperBrowser.bookmarks().length,before:before,
            downloadDirectory:viperBrowser.downloadDirectory()})
    }
    function auditBrowserTouchSnapshot() {
        const view=activeBrowser && activeBrowser.index===browserTabs.currentIndex ? activeBrowser : null
        const touchHandler=view?findControl(view,"browserTouchScrollFallback"):null
        return JSON.stringify({drag:browserTouchDragDistance,
            scroll:view?view.scrollPosition.toString():"no-view",
            scrollY:view?view.scrollPosition.y:-1,
            url:view?view.url.toString():"no-view",
            size:view?view.contentsSize.toString():"no-view",
            dragActive:touchHandler?touchHandler.active:false})
    }
    function auditOpenBrowserTools() { browserTools.open(); return true }
    function auditCloseBrowserTools() { browserTools.close() }
    function auditBrowserToolsSnapshot() {
        const menuVisual=browserTools.contentItem
        const menuPos=menuVisual.mapToItem(win.contentItem,0,0)
        const quickMenuItem=browserQuickActions
        const quickContent=quickMenuItem.contentItem
        const quickRow=findControl(quickContent,"browserQuickActionRow")
        const quickButtons=["browserQuickBack","browserQuickForward","browserQuickBookmark","browserQuickCloseTab","browserQuickReload"]
        const quickButtonWidths=[]
        for(let i=0;i<quickButtons.length;++i){const button=findControl(quickContent,quickButtons[i]);quickButtonWidths.push(button?button.width:0)}
        return JSON.stringify({narrow:narrow,visible:browserTools.visible,height:menuVisual.height,
            width:menuVisual.width,x:menuPos.x,y:menuPos.y,
            right:menuPos.x+menuVisual.width,bottom:menuPos.y+menuVisual.height,quickHeight:quickMenuItem.height,
            quickRowWidth:quickRow?quickRow.implicitWidth:0,quickContentWidth:quickContent.width,
            quickButtons:quickButtonWidths,
            zoomVisible:browserZoomControls.visible,zoomHeight:browserZoomControls.height,zoomWidth:browserZoomControls.width,
            zoomOutHeight:browserZoomOut.height,zoomInHeight:browserZoomIn.height,zoomPercent:browserZoomPercent.text})
    }
    function rememberCurrentBrowser() {
        if(!activeBrowser)return
        viperBrowser.addBookmark(activeBrowser.url,activeBrowser.title)
        browserBookmarks=viperBrowser.bookmarks()
    }
    function addBrowserTab() {
        if(tabs.count>=8)return
        tabs.append({address:viperBrowser.newTabUrl(),privateMode:false});browserTabs.currentIndex=tabs.count-1
    }
    function closeBrowserTab() {
        if(tabs.count<=1)return
        const index=browserTabs.currentIndex;browserTabs.currentIndex=0;tabs.remove(index)
    }
    function enqueueBrowserDownload(request) {
        if(!request)return
        const directory=viperBrowser.downloadDirectory()
        const name=safeBrowserDownloadName(request.suggestedFileName)
        if(!directory) {
            request.cancel()
            browserDownloads=browserDownloads.concat([{request:null,name:name,url:request.url.toString(),path:"",status:I18n.t("下载目录不可用"),received:0,total:0}])
            Qt.callLater(function(){browserDownloadsDialog.open()})
            return
        }
        if(request.state===WebEngineDownloadRequest.DownloadRequested) {
            request.downloadDirectory=directory
            request.downloadFileName=name
        }
        browserDownloads=browserDownloads.concat([{request:request,name:name,url:request.url.toString(),path:directory+"/"+name,status:I18n.t("正在下载"),received:0,total:0}])
        // Qt 6.4 destroys an unaccepted QML download request as soon as this
        // signal handler returns. Accept synchronously before showing any UI.
        if(request.state===WebEngineDownloadRequest.DownloadRequested)request.accept()
        if(request.isFinished)finishBrowserDownload(request)
        Qt.callLater(function(){browserDownloadsDialog.open()})
    }
    function safeBrowserDownloadName(value) {
        let name=String(value||"").trim().replace(/[\\/]/g,"_").replace(/[\x00-\x1f\x7f]/g,"_")
        if(name==="."||name==="..")name=""
        return name||("download-"+Date.now())
    }
    function updateBrowserDownload(request,patch) {
        const records=browserDownloads.slice()
        for(let i=0;i<records.length;++i)if(records[i].request===request){records[i]=Object.assign({},records[i],patch);browserDownloads=records;return i}
        return -1
    }
    function browserDownloadFinishedStatus(request) {
        if(request.state===WebEngineDownloadRequest.DownloadCompleted)return I18n.t("已完成")
        if(request.state===WebEngineDownloadRequest.DownloadCancelled)return I18n.t("已取消")
        if(request.state===WebEngineDownloadRequest.DownloadInterrupted) {
            const reason=request.interruptReasonString||""
            if(!reason||reason.toLowerCase().indexOf("unknown reason or not interrupted")>=0)
                return I18n.t("下载中断，原因未知")
            return I18n.t("下载中断")+"："+reason
        }
        return request.interruptReasonString||I18n.t("下载中断，原因未知")
    }
    function finishBrowserDownload(request) {
        updateBrowserDownload(request,{status:browserDownloadFinishedStatus(request),received:request.receivedBytes,total:request.totalBytes,path:request.downloadDirectory+"/"+request.downloadFileName,request:null})
    }
    function auditOpenWindow(route) {go(route);zoomAnimation.complete()}
    function auditTaskCount(){return openTasks.count}
    function auditMinimizeMain(){if(phase==="opening")zoomAnimation.complete();minimizeApp()}
    function auditRestoreMain(){appMinimized=false;phase="open";updateTaskState()}
    function auditTaskbarRestore(){
        const row=taskRow(appEntryId)
        if(row) switchTask({entryId:row.entryId,title:row.title,iconName:row.iconName,accentColor:row.accentColor,route:row.route,instance:row.instance,ready:true})
    }
    function auditHomeRequest(){if(phase==="open")minimizeApp()}
    function auditHomeReopen(){const row=taskRow(appEntryId);if(row)launch(row,width/2,contentItem.height/2)}
    function auditToggleAppMaximize(){appMaximized=!appMaximized;updateTaskState()}
    function auditSnapshot() {
        return JSON.stringify({width:width,height:height,scale:uiScale,textScale:textScale,body:Theme.body,title:Theme.title,gap:Theme.gap,hit:Theme.hit,
            section:section,phase:phase,openProgress:openProgress,carouselX:launcher.contentX,cardCount:homeCards.count,
            homeContentWidth:homePane.width,homeViewportWidth:homePane.width})
    }
    function auditKeyboardDictionary() {
        auditPage(4)
        const input=keyboardAuditInput
        if (input) {input.text="";input.forceActiveFocus()}
        screenKeyboard.show()
        screenKeyboard.ensureDictionaryLoaded()
        const inputCode="nihao"
        for(let i=0;i<inputCode.length;++i)screenKeyboard.typeLetter(inputCode[i])
        const snapshot={visible:screenKeyboard.visible,loaded:screenKeyboard.dictionaryLoaded,
            candidate:screenKeyboard.currentCandidates.indexOf("你好")>=0,
            letters:["qwertyuiop","asdfghjkl","zxcvbnm"].join("").length,
            width:screenKeyboard.width,height:screenKeyboard.height,
            candidates:screenKeyboard.currentCandidates.slice(0,6)}
        screenKeyboard.commitCandidate("你好")
        snapshot.input=!!input && input.text==="你好"
        if (input) input.text=""
        return JSON.stringify(snapshot)
    }
    function auditWindowAnimation() {
        auditPage(4)
        windowAnimationAuditSnapshot={normalWidth:appShell.width,maxWidth:win.width,
            maximizeSamples:[],minimizeSamples:[],restoreSamples:[],passed:false}
        windowAnimationAuditStage=0;windowAnimationAuditTicks=0;windowAnimationAuditTimer.start()
    }
    Timer {
        id:windowAnimationAuditTimer;interval:40;repeat:true
        onTriggered: {
            const audit=win.windowAnimationAuditSnapshot
            if(win.windowAnimationAuditStage===0) {
                audit.normalWidth=appShell.width
                win.toggleMaximize();win.windowAnimationAuditStage=1;win.windowAnimationAuditTicks=0
            } else if(win.windowAnimationAuditStage===1) {
                audit.maximizeSamples.push(appShell.width)
                if(++win.windowAnimationAuditTicks>=8) {win.toggleMaximize();win.windowAnimationAuditStage=2;win.windowAnimationAuditTicks=0}
            } else if(win.windowAnimationAuditStage===2) {
                if(++win.windowAnimationAuditTicks>=8) {win.minimizeApp();win.windowAnimationAuditStage=3;win.windowAnimationAuditTicks=0}
            } else if(win.windowAnimationAuditStage===3) {
                audit.minimizeSamples.push(win.openProgress)
                if(win.phase==="home") {win.restoreApp();win.windowAnimationAuditStage=4;win.windowAnimationAuditTicks=0}
            } else if(win.windowAnimationAuditStage===4) {
                audit.restoreSamples.push(win.openProgress)
                if(win.phase==="open" && ++win.windowAnimationAuditTicks>=8) {
                    audit.maximizeAnimated=audit.maximizeSamples.some(function(v){return v>audit.normalWidth+4 && v<audit.maxWidth-4})
                    audit.minimizeAnimated=audit.minimizeSamples.some(function(v){return v>0.1 && v<0.95})
                    audit.restoreAnimated=audit.restoreSamples.some(function(v){return v>0.1 && v<0.99})
                    audit.passed=audit.maximizeAnimated && audit.minimizeAnimated && audit.restoreAnimated
                    console.log("WINDOW_ANIMATION_AUDIT "+JSON.stringify(audit))
                    windowAnimationAuditTimer.stop()
                }
            }
        }
    }
    function auditPage(page) {
        pendingLaunch=null
        if(phase!=="home") {
            closeApp()
            zoomAnimation.complete()
            // complete() 只把动画推到终点，不保证走 onFinished；不调用
            // finishTransition 会留下 section!=0 的隐藏 appShell，后续 resize
            // 会进入坏掉的布局。审计/测试必须显式收尾。
            if(phase==="closing") finishTransition()
        }
        if(page>0){go(page);zoomAnimation.complete()}
    }
    function auditNetworkPanel(show) {
        win.aboutDeviceOpen=false
        win.networkPermissionsOpen=show
    }
    function auditNetworkPanelSnapshot() {
        const panel=networkPermissionsPageLoader.item
        return JSON.stringify({section:section,phase:phase,open:win.networkPermissionsOpen,
            loaded:!!panel,visible:panel?panel.visible:false,shown:panel?panel.shown:false,
            x:panel?panel.x:-1,width:panel?panel.width:0})
    }
    function targetPageAudit() {
        let count=0,fit=true
        if(section===6) for(let i=0;i<calculatorGrid.children.length;++i) {
            const key=calculatorGrid.children[i]
            if(!key || key.keySize===undefined)continue
            count++
            if(key.keySize<40*uiScale || key.keySize>calculatorGrid.width/4+1)fit=false
        }
        if(section===6 && calculatorGrid.height>calculatorFlick.height+1)fit=false
        const browserView=section===2?browserRepeater.itemAt(browserTabs.currentIndex):null
        const browserWheelButton=section===2?findControl(win.contentItem,"browserWheelToggle"):null
        const browserWheelItem=section===2?findControl(win.contentItem,"browserWheel"):null
        return JSON.stringify({section:section,maximized:appMaximized,calculatorKeyCount:count,calculatorFits:fit,
            browserHeight:browserView?browserView.height:0,browserWidth:browserView?browserView.width:0,
            activeBrowserReady:!!activeBrowser,browserViewGeneration:browserViewGeneration,phase:phase,
            browserWheelToggleEnabled:browserWheelButton?browserWheelButton.enabled:false,
            browserWheelRequested:browserWheelEnabled,
            browserWheelVisible:browserWheelItem?browserWheelItem.visible:false,
            browserWheelEnabled:browserWheelItem?browserWheelItem.enabled:false,
            browserWheelSize:browserWheelItem?{width:browserWheelItem.width,height:browserWheelItem.height}:null})
    }
    function auditScale(value) {textScale=value}
    function auditDialog(kind) {
        if (kind === "trust") { trustItem={instance:"audit-only",title:I18n.t("测试模块"),permissions:["transport.ble","transport.hotspot_lan"]}; trustDialog.open() }
        else if (kind === "file") { filePath="audit.txt"; viewer.text=I18n.t("响应式文件编辑器"); fileDialog.open() }
        else if(kind==="file-operation")requestFileOperation("newFile")
        else if(kind==="opacity")opacityDialog.open()
        else if (kind === "bookmarks") { browserBookmarks=[{title:"Terminal example",url:"https://example.invalid/书签示例"}];bookmarkDialog.open() }
        else if(kind==="status")showDevicePanel(false)
        else { trustDialog.close(); fileDialog.close();fileOperationDialog.close();bookmarkDialog.close();devicePanel.close();opacityDialog.close() }
    }
    ListModel { id: homeCards }
    ListModel {id:recentApps}
    ListModel {id:notices}
    Connections {
        target: connectionManager
        function onCardsChanged() {
            syncCards()
            for (let row of connectionManager.cards) if (row.instance===activeSession) moduleMessage=row.message
        }
        function onTrustRequired(instance,title,permissions) { trustQueue.push({instance:instance,title:title,permissions:permissions}); showNextTrust() }
        function onPageMustClose(instance) {
            if(activeSession===instance){
                if(releaseQueue.indexOf(instance)<0)releaseQueue.push(instance)
                if(phase==="home") { clearForegroundModulePage();releaseQueue=releaseQueue.filter(function(id){return id!==instance}); Qt.callLater(function(){connectionManager.releasePage(instance)}) }
                else closeApp()
            }
            else Qt.callLater(function(){connectionManager.releasePage(instance)})
            trustQueue=trustQueue.filter(function(item) { return item.instance!==instance })
            if (trustItem.instance===instance) trustDialog.close()
        }
        function onDeviceAttached(instance,moduleId) {if(phase==="home")Qt.callLater(function(){launcher.reveal(instance)})}
    }
    Connections { target: systemTools; function onChanged() {
        const wallpaperUrl=systemTools.wallpaper.toString()
        if(observedWallpaperUrl!==wallpaperUrl) {
            observedWallpaperUrl=wallpaperUrl
            windowBlurCache.requestUpdate();panelBlurCache.requestUpdate()
            if(appShell.visible)appBackdropRefreshTimer.start()
        }
        browserBookmarks=viperBrowser.bookmarks()
        // A status refresh must not destroy/recreate every launcher FBO while
        // opening the quick panel. Only language changes affect built-in titles.
        if(observedUiLanguage!==systemTools.uiLanguage) {
            observedUiLanguage=systemTools.uiLanguage;syncCards()
            if(section!==5 && section>0)appTitle=builtin(section).title
            for(let i=0;i<openTasks.count;++i)if(openTasks.get(i).route!==5)openTasks.setProperty(i,"title",builtin(openTasks.get(i).route).title)
        }
    }
        // 启动阶段的日志（如“语音输出切换…”）不再弹横幅，只进运行记录。
        function onNotification(message){ if(!message || !message.trim() || !win.startupComplete || Date.now()-win.bootAt < 8000) return; win.notify("",message,false) } }
    Connections {
        target:connectionManager
        // 模块包更新后不重启终端：重新加载当前模块页。
        function onModuleRefreshed(instance, version) {
            if (instance !== activeSession) return
            notify("", I18n.t("模块已更新到版本 ") + version, false, appTitle);
            openModule(activeSession)
        }
        function onBridgeUnavailable() {
            win.notify("",I18n.t("超过5秒未连接控制桥，请检查USB连接。现有无线数据会话不受此提示影响。"),true,I18n.t("控制桥"),"lan")
            systemTools.speak(I18n.t("控制桥已断开，请检查USB连接"))
        }
        function onBridgeConnectionChanged() {
            if(connectionManager.bridgeConnected) showBridgeConnectedPrompt()
        }
    }
    function showBridgeConnectedPrompt() {
        bridgeConnectedPromptShown=true
        if(bannerAppName===I18n.t("控制桥") && bannerImportant) {notificationBanner.close();bannerTimer.stop()}
        win.notify(I18n.t("控制桥已连接"),I18n.t("USB控制桥已连接，可以连接模块。"),false,I18n.t("控制桥"),"lan")
    }
    Timer { id:bannerTimer; onTriggered:notificationBanner.close() }
    Popup {
        id:notificationBanner;objectName:"notificationBanner";parent:Overlay.overlay
        x:(win.width-width)/2;y:Theme.gap;width:Math.min(win.width-Theme.gap*2,720*uiScale)
        padding:Theme.gap;modal:false;closePolicy:Popup.NoAutoClose
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeLarge;borderColor:bannerImportant?"#ffc66d":Theme.outline;borderWidth:2}
        enter:Transition {NumberAnimation {property:"opacity";from:0;to:1;duration:140}}
        exit:Transition {NumberAnimation {property:"opacity";from:1;to:0;duration:100}}
        contentItem:ColumnLayout {
            spacing:Theme.gap/2
            RowLayout {
                Layout.fillWidth:true
                MaterialIcon {name:bannerIconName;Layout.preferredWidth:28*uiScale;Layout.preferredHeight:28*uiScale}
                CarText {text:bannerAppName+"，"+bannerTime;font.pointSize:Theme.body;font.weight:Font.DemiBold;color:Theme.secondary;Layout.fillWidth:true}
                IconButton {iconName:"close";label:I18n.t("关闭通知横幅");onClicked:{notificationBanner.close();bannerTimer.stop()}}
            }
            CarText {objectName:"notificationBannerTitle";visible:bannerTitle!=="";text:bannerTitle;color:Theme.foreground;font.pointSize:Theme.body*1.05;font.weight:Font.DemiBold;Layout.fillWidth:true;wrapMode:Text.Wrap}
            CarText {objectName:"notificationBannerMessage";text:bannerMessage;color:Theme.foreground;font.pointSize:Theme.body;Layout.fillWidth:true;wrapMode:Text.Wrap}
            Button {
                id:openNotificationsButton
                property bool auditControl:true
                Layout.alignment:Qt.AlignRight
                implicitHeight:Theme.hit
                Accessible.name:I18n.t("查看通知")
                onClicked:{notificationBanner.close();bannerTimer.stop();showDevicePanel(true)}
                background:Rectangle {radius:Theme.shapeFull;color:openNotificationsButton.down?Theme.pressed:"transparent"}
                contentItem:RowLayout {
                    spacing:Theme.gap/2
                    MaterialIcon {name:"notifications";Layout.preferredWidth:Theme.icon;Layout.preferredHeight:Theme.icon}
                    CarText {text:I18n.t("查看通知");color:Theme.accent;Layout.fillWidth:true}
                }
            }
        }
    }

    // Render these behind the opaque desktop, never inside their own source.
    BlurCache {id:windowBlurCache;inputReady:win.blurInputReady;backdrop:desktopBackground;levels:efficientRendering?2:4;resolutionScale:efficientRendering?0.25:0.5;strength:2}
    BlurCache {id:panelBlurCache;inputReady:win.blurInputReady;backdrop:desktopBackground;levels:efficientRendering?2:4;resolutionScale:efficientRendering?0.25:0.5;strength:3.2;rectMapper:win.panelBlurRect}
    function panelBlurRect(item) {
        // Geometry dependencies update UVs in the same polish/frame as layout.
        // The atlas stays frozen: no source captures or blur passes while sliding.
        let geometry=devicePanel.position
        for(let node=item;node;node=node.parent)geometry+=node.x+node.y+node.width+node.height
        if(!isFinite(geometry) || !devicePanel.parent || !devicePanel.background)return Qt.rect(0,0,1,1)
        const p=item.mapToItem(desktopBackground,0,0)
        const current=devicePanel.background.mapToItem(desktopBackground,0,0)
        const target=devicePanel.parent.mapToItem(desktopBackground,devicePanel.x,devicePanel.parent.height-devicePanel.height)
        return Qt.rect(p.x+target.x-current.x,p.y+target.y-current.y,Math.max(1,item.width),Math.max(1,item.height))
    }
    // Capture only the background, excluding UI and blur outputs (no feedback).
    Item {
        // Overlay drawers include the footer; their shared source must too.
        id:desktopBackground;objectName:"desktopBackground"
        anchors.top:parent.top;anchors.left:parent.left;anchors.right:parent.right
        height:win.height
    Rectangle {
        id: sceneSource; anchors.fill: parent; color: "#071827"
        Rectangle { width: parent.width*0.65; height: parent.height*0.7; x:-width*0.12; y:parent.height*0.13
            radius: Math.min(width,height)*0.5; rotation:-22; color:"#14546c" }
        Rectangle { width: parent.width*0.5; height: parent.height*0.65; x:parent.width*0.64; y:-height*0.1
            radius: Math.min(width,height)*0.5; color:"#413764" }
        Repeater { model: 6; Rectangle {
            required property int index
            x:sceneSource.width*(0.12+index*0.14); y:sceneSource.height*0.45; width:sceneSource.width*0.018
            height:sceneSource.height*0.9; rotation:48; color:index%2 ? "#24617b" : "#162b49"
    } }
    Timer {
        id:appBackdropRefreshTimer;interval:120;repeat:false
        onTriggered:if(appShell.visible) {
            windowBackdrop.live=false
            windowBackdrop.scheduleUpdate()
            appBackdropRefreshResume.start()
            appBackdropRefreshCount++
        }
    }
    Timer {id:appBackdropRefreshResume;interval:80;repeat:false;onTriggered:windowBackdrop.live=true}
    }
     // Two levels preserve the soft background effect while avoiding four
     // extra FBO passes on low-end/software-rendered boards.
         BlurItem { objectName:"backgroundGpuBlur"; anchors.fill:parent; source:sceneSource; visible:!repairRawDefault; levels:efficientRendering?2:4; strength:2.0; resolutionScale:efficientRendering?0.25:0.5 }
    Rectangle { anchors.fill:parent; color:"#08121f"; opacity:0.72 }
    Image {
        id:homeWallpaper;objectName:"homeWallpaper";anchors.fill:parent;clip:true
        visible:status===Image.Ready
        // Wallpaper is static: cache its source texture. Unlike carousel crops,
        // this layer changes only on image load or window geometry changes.
        source:systemTools.wallpaper;fillMode:Image.PreserveAspectCrop;autoTransform:true
        sourceSize.width:Math.ceil(win.width*Screen.devicePixelRatio)
         asynchronous:true
         onStatusChanged:if(status===Image.Ready || source.toString()===""){windowBlurCache.requestUpdate();panelBlurCache.requestUpdate()}
     }
     BlurItem {
         objectName:"customWallpaperBlur";anchors.fill:parent
          visible:homeWallpaper.status===Image.Ready && !repairRawWallpaper
         source:visible?homeWallpaper:null
           levels:efficientRendering?2:4;strength:2.0;resolutionScale:efficientRendering?0.25:0.5
     }
    }
    CachedBlur {
         objectName:"moduleBackgroundBlur";anchors.fill:parent;source:windowBlurCache.activeTexture||desktopBackground
           preblurred:windowBlurCache.ready
          levels:efficientRendering?2:4;strength:2.0;mixAmount:1.0
          resolutionScale:efficientRendering?0.25:0.5
           visible:phase!=="home" && !appMinimized && !repairRawAppBlur
        opacity:openProgress
    }

    AlarmEngine {
        id:alarmEngine
        onNotifyRequested:function(title,message,important){win.notify(title,message,important,I18n.t("时间"),"alarm")}
        onAnnounceRequested:function(text){win.announce(text)}
    }
    // 校时状态活在页面之外：设置页分区与时间页看到的是同一份城市/线路状态。
    TimeSync {id:timeSync;objectName:"timeSync"}
    // 天气状态同样活在页面之外：切换页面不会丢数据，设置页与天气页共用一份地点/缓存。
    WeatherEngine {id:weatherEngine;objectName:"weatherEngine";active:win.section===14 && win.phase!=="home"}

    footer:StatusDock {
        id:statusDock
        visible:!win.repairBackdropOnly && !win.videoFullscreen
        status:systemTools.deviceStatus;recentModel:openTasks;unread:unreadNotifications;clock:clockText;appOpen:phase!=="home";activeEntryId:appEntryId
        alarmActive:alarmEngine.hasEnabledAlarms
        onAppDrawerRequested:appDrawer.open()
        onStatusRequested:showDevicePanel(false)
        onNotificationsRequested:showDevicePanel(true)
        onKeyboardRequested:screenKeyboard.show()
        onAlarmsRequested:win.openAlarms()
        onRecentRequested:function(entry){switchTask(entry)}
    }
    Loader {
        id:desktopPetLoader
        objectName:"desktopPetLoader"
        // A dedicated top layer of the normal application content. Controls'
        // Popup Overlay may hide itself when the startup Loader is unloaded;
        // pets must not depend on a Popup being open to remain visible.
        parent: win.contentItem
        anchors.fill: parent
        z: 900
        active: win.petEasterEggEnabled
        // The inline sourceComponent is instantiated with its own QML scope on
        // Qt 6.4. Pass outer objects explicitly instead of relying on outer
        // ids (notably `win`) resolving inside that component.
        onLoaded: {
            item.hostWindow = win
            item.hostStatusDock = statusDock
            item.hostPetManager = petManager
            item.hostPetMenu = petEasterEggMenu
            item.hostTrustDialog = trustDialog
            item.hostPowerConfirm = powerConfirm
            item.hostSystemActionsDialog = systemActionsDialog
        }
        sourceComponent: DesktopPet {
            id:desktopPet
            anchors.fill: parent
        }
    }
    PetManager {
        id:petManager;parent:Overlay.overlay
        availableBottom:win.contentItem.height
        virtualKeyboard:screenKeyboard
        onKeyboardRequested:screenKeyboard.show()
    }
    Menu {
        id:petEasterEggMenu;parent:Overlay.overlay
        objectName:"petEasterEggMenu"
        width:Math.min(240,win.width-24)
        MenuItem {objectName:"petEasterEggToggle";height:Math.max(48,implicitHeight);text:win.petEasterEggEnabled?I18n.t("关闭桌宠"):I18n.t("启动桌宠");onTriggered:win.petEasterEggEnabled=!win.petEasterEggEnabled}
        MenuItem {objectName:"petEasterEggManage";height:Math.max(48,implicitHeight);text:I18n.t("桌宠管理");onTriggered:petManager.open()}
    }
    FloatingKeyboard {
        id:screenKeyboard
        // 必须压过登入门禁(20000)、解锁遮罩(31000)、开发者面板与建号覆盖层(30000)，
        // 但低于首次开机向导(50000)与删账户等待层(45000)。
        z:36000
        uiScale:win.uiScale
        hostWindow:win
        onVisibleChanged:Qt.callLater(win.updateKeyboardShift)
        onYChanged:Qt.callLater(win.updateKeyboardShift)
        onHeightChanged:Qt.callLater(win.updateKeyboardShift)
    }
    Connections {
        target:win
        function onActiveFocusItemChanged(){Qt.callLater(win.updateKeyboardShift)}
        function onUiScaleChanged(){Qt.callLater(win.updateKeyboardShift)}
    }
    Item {
        id:homePane;objectName:"homePane";anchors.fill:parent;anchors.margins:win.edge;visible:phase!=="open"&&!repairBackdropOnly;enabled:phase==="home" && !sessionManager.locked
        opacity:phase==="home"?1:1-openProgress*0.3
            RowLayout {id:homeHeader;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;height:Theme.hit;spacing:Theme.gap
                CarText {text:I18n.t("应用");heading:true;Layout.fillWidth:true}
                // 副标题与编辑控件共用一块位置：编辑时副标题让位给 取消/恢复默认/完成。
                CarText {objectName:"appLayoutHint";visible:!narrow && !launcher.editMode
                    text:connectionManager.cards.length?connectionManager.cards.length+I18n.t(" 个模块已接入"):launcher.pageCount>1?I18n.t("左右滑动浏览应用"):I18n.t("点按图标打开应用");subdued:true}
                // 登出：访客结束临时会话（连数据一起删），正式用户登出回登录页。
                // 位置在"左右滑动浏览应用"与编辑图标之间；编辑期间与提示条一起让位，
                // 退出编辑后回来。窄屏（提示条隐藏）仍保留，避免退不出去。
                IconButton {objectName:"sessionLogout";iconName:"logout"
                    accentColor:Theme.warning
                    label:sessionManager.guestSession?I18n.t("退出访客会话"):I18n.t("退出登录")
                    visible:sessionManager.loggedIn && !launcher.editMode
                    onClicked: sessionManager.guestSession ? sessionManager.endGuestSession()
                                                           : sessionManager.signOut()}
                // 编辑用 tune（调节）图标；进入后取消=×、完成=✓。
                IconButton {objectName:"appLayoutEdit";iconName:"build";label:I18n.t("编辑应用布局")
                    visible:!launcher.editMode;onClicked:launcher.enterEdit()}
                IconButton {objectName:"appLayoutCancel";iconName:"close";label:I18n.t("取消")
                    visible:launcher.editMode;onClicked:launcher.cancelEdit()}
                IconButton {objectName:"appLayoutReset";iconName:"refresh";label:I18n.t("恢复默认布局")
                    visible:launcher.editMode;onClicked:launcher.resetOrder()}
                IconButton {objectName:"appLayoutDone";iconName:"check";label:I18n.t("完成")
                    visible:launcher.editMode;filled:true;onClicked:launcher.finishEdit()}
                IconButton {iconName:"tune";label:I18n.t("设备快捷设置");onClicked:showDevicePanel(false)}
                IconButton {iconName:"minimize";label:I18n.t("返回桌面");onClicked:desktopShell.showDesktop()}
            }
            AppLauncher {id:launcher;backgroundSource:desktopBackground;backgroundBlurTexture:windowBlurCache.activeTexture;anchors.left:parent.left;anchors.right:parent.right;anchors.bottom:parent.bottom;anchors.top:homeHeader.bottom;anchors.topMargin:Theme.gap;model:homeCards;revision:homeRevision;defaultOrder:win.appDefaultOrder
                onActivated:function(entry,x,y){launch(entry,x,y)}
                onRestrictedActivated:function(entry){restrictedNotice.show(entry.title)}}
    }
    Item {
        id:appShell;objectName:"animatedAppSurface"
        x:videoFullscreen || appMaximized || narrow?0:win.width*0.08; y:videoFullscreen || appMaximized || narrow?0:win.contentItem.height*0.06
        width:videoFullscreen || appMaximized || narrow?win.width:win.width*0.84; height:videoFullscreen || appMaximized || narrow?win.contentItem.height:win.contentItem.height*0.84
        visible:section!==0 && !appMinimized;enabled:phase==="open";opacity:openProgress
        // 二级页从 pages 右缘滑入时仍属于 appShell；不裁切会让页面的右半截
        // 在应用窗口外再画一份，随缩放看起来像"上一个菜单闪了一下"。
        clip:true
        Behavior on x {NumberAnimation {duration:300;easing.type:Easing.InOutCubic}}
        Behavior on y {NumberAnimation {duration:300;easing.type:Easing.InOutCubic}}
        Behavior on width {NumberAnimation {duration:300;easing.type:Easing.InOutCubic}}
        Behavior on height {NumberAnimation {duration:300;easing.type:Easing.InOutCubic}}
        transform:Scale {id:appScale;origin.x:win.originX;origin.y:win.originY;xScale:0.12+0.88*openProgress;yScale:xScale}
         ShaderEffectSource {
             id:windowBackdrop;parent:desktopBackground.parent;z:-99;width:1;height:1;sourceItem:windowBlurCache.ready?null:desktopBackground;live:true
             sourceRect:{const geometry=appShell.x+appShell.y+appScale.xScale+appScale.yScale+appScale.origin.x+appScale.origin.y;if(!isFinite(geometry))return Qt.rect(0,0,1,1);const p=appShell.mapToItem(desktopBackground,0,0);return Qt.rect(p.x,p.y,appShell.width,appShell.height)}
         }
         CachedBlur {objectName:"windowBackdropBlur";anchors.fill:parent;source:windowBlurCache.activeTexture||windowBackdrop
             preblurred:windowBlurCache.ready
             sourceRect:windowBlurCache.ready?Qt.rect(windowBackdrop.sourceRect.x/windowBlurCache.activeTexture.width,windowBackdrop.sourceRect.y/windowBlurCache.activeTexture.height,windowBackdrop.sourceRect.width/windowBlurCache.activeTexture.width,windowBackdrop.sourceRect.height/windowBlurCache.activeTexture.height):Qt.rect(0,0,1,1)
             visible:!repairRawAppBlur;levels:efficientRendering?2:4;resolutionScale:windowBlurCache.ready?windowBlurCache.activeTexture.resolutionScale:efficientRendering?0.25:0.5;strength:2;cornerRadius:Theme.shapeExtraLarge}
        Rectangle {objectName:"windowTint";anchors.fill:parent;color:Theme.background;opacity:systemTools.moduleOpacity;radius:Theme.shapeExtraLarge}
        Item {
             anchors.fill:parent;anchors.margins:videoFullscreen?0:Math.max(win.edge,Theme.shapeExtraLarge+Theme.gap/2)
             RowLayout {id:windowTitleBar;objectName:"windowTitleBar";visible:!videoFullscreen;anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top;height:Theme.hit;spacing:Theme.gap
                 AppIcon {visible:!narrow;iconName:appIcon;accentColor:({connections:"#ad8cff",browser:"#4fd4a4",files:"#ffbd54",settings:"#4c9dff",calculator:"#ff9d37",paint:"#ff6584",notes:"#36c8db",music:"#d889e8",video:"#65c9bd"})[appEntryId] || "#85deff";Layout.preferredWidth:36*uiScale;Layout.preferredHeight:36*uiScale}
                CarText {text:appTitle;heading:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                IconButton {visible:!narrow;iconName:"minimize";label:I18n.t("最小化应用窗口");onClicked:minimizeApp()}
            IconButton {visible:!narrow;iconName:appMaximized?"close_fullscreen":"fullscreen";label:appMaximized?I18n.t("恢复应用窗口"):I18n.t("最大化应用窗口");onClicked:toggleMaximize()}
                IconButton {objectName:"closeAppButton";iconName:"close";label:I18n.t("关闭当前应用");onClicked:{announce(I18n.t("关闭当前应用"));closeApp()}}
            }
            StackLayout {
        id:pages;anchors.left:parent.left;anchors.right:parent.right;anchors.top:videoFullscreen?parent.top:windowTitleBar.bottom;anchors.bottom:parent.bottom;anchors.topMargin:videoFullscreen?0:Theme.gap;currentIndex:Math.max(0,win.section-1)
        // 键盘避让（参考宠物菜单：按键盘 y 收可用高度）。
        // 1) 可视区底部收到键盘上沿，页面在剩下的空间里滚动，下半屏不会被键盘永久盖住；
        // 2) 聚焦输入框若仍被遮，再用 translate 整体上移补足。
        transform: Translate {
            y: -win.keyboardShift
            // 只在键盘可见时做动画：收起键盘的瞬间内容已经在重新布局，
            // 再叠一段位移动画会看到「先弹上去再落回来」。
            Behavior on y {
                enabled: screenKeyboard.visible
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
        }
        // MODULES: wrap toolbar controls, never compress a single fixed row.
        Item {
        id:connectionPageRoot
        Flickable {
            id:moduleFlick; objectName:"connectionPage"; anchors.fill:parent; clip:true; contentWidth:width
            contentHeight:connectionPageLoader.item ? connectionPageLoader.item.implicitHeight : 0
            boundsBehavior:Flickable.StopAtBounds; flickableDirection:Flickable.VerticalFlick
            // This page is hidden while any other module is open. Building its
            // wrapped column at a transient 313x149 size made Qt 6.5 abort a
            // polish loop; keep it unloaded until the connections page is open.
            Loader {
                id:connectionPageLoader
                width:moduleFlick.width
                active:win.section===1 && win.phase!=="home"
                sourceComponent:Component {
            ColumnLayout {
                id:moduleColumn; width:moduleFlick.width; spacing:Theme.gap
                RowLayout { Layout.fillWidth:true; spacing:Theme.gap
                    CarText {text:I18n.t("这里只管理连接。模块功能请从主页图标打开。");Layout.fillWidth:true;subdued:true}
                    // 访客只灰显（图标小，不加锁角标），点击弹无权限。
                    IconButton {objectName:"connectionSettingsGear";iconName:"settings"
                        opacity:sessionManager.guestSession?0.4:1
                        label:I18n.t("连接设置")
                        onClicked: sessionManager.guestSession ? restrictedNotice.show(I18n.t("连接设置"))
                                                               : win.connectionSettingsOpen=true}
                }
                Flow {
                    visible:desktopDebug; Layout.fillWidth:true; spacing:Theme.gap
                    IconButton {iconName:"apps";label:I18n.t("插入示例");onClicked:connectionManager.attach({event:"attach",module_id:80,module_instance:"desktop-demo"})}
                    IconButton {iconName:"close";label:I18n.t("拔出触点");onClicked:connectionManager.attach({event:"detach",module_id:80,module_instance:"desktop-demo"})}
                    IconButton {iconName:"close";label:I18n.t("结束会话");onClicked:connectionManager.disconnectModule("desktop-demo")}
                }
                 CarText { text:I18n.t(connectionManager.status); Layout.fillWidth:true; padding:Theme.gap
                    background:Rectangle { color:Theme.surface; radius:Theme.shapeMedium } }
                Repeater {
                    model:connectionManager.cardModel
                    Rectangle {
                        required property var cardData
                        Layout.fillWidth:true; implicitHeight:sessionContent.implicitHeight+Theme.gap*2
                        color:Theme.surface; radius:Theme.shapeLarge; border.color:Theme.outline
                        ColumnLayout {
                            id:sessionContent; anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top
                            anchors.margins:Theme.gap; spacing:Theme.gap
                            CarText { text:cardData.title; heading:true; Layout.fillWidth:true }
                             CarText { text:cardData.state==="contact_detached"?stateText(cardData.state):stateText(cardData.state)+(cardData.contact ? I18n.t("，触点已接入") : I18n.t("，无线会话")); subdued:true; Layout.fillWidth:true }
                            ProgressBar { value:cardData.progress/100; Layout.fillWidth:true
                                contentItem:Rectangle { implicitHeight:8*uiScale; color:Theme.raised
                                    Rectangle { width:parent.width*parent.parent.position; height:parent.height; color:Theme.accent } } }
                            Flow { Layout.fillWidth:true; spacing:Theme.gap
                                IconButton {iconName:"extension";label:I18n.t("打开模块");enabled:cardData.ready;onClicked:openModule(cardData.instance)}
                                IconButton {iconName:"close";label:I18n.t("断开模块");onClicked:{announce(I18n.t("请求断开模块"));connectionManager.disconnectModule(cardData.instance)}}
                                IconButton {iconName:"refresh";label:I18n.t("重试连接");visible:cardData.state==="error";onClicked:connectionManager.retry(cardData.instance)}
                            }
                        }
                    }
                }
            }
                }
            }
        }
        ConnectionSettingsPage {
            id:connectionSettingsPage
            width:parent.width;height:parent.height
            open:win.connectionSettingsOpen
            onCloseRequested:win.connectionSettingsOpen=false
            onKeyboardRequested:screenKeyboard.show()
        }
        }
        // BROWSER: short or portrait screens use a scrollable toolbar over a sizeable viewport.
    Flickable {
            id:browserFlick; objectName:"browserPage"; clip:true; contentWidth:width; contentHeight:height
            Layout.fillWidth:true;Layout.fillHeight:true
            interactive:false
            ColumnLayout {
                id:browserColumn; anchors.fill:parent; spacing:Theme.gap
                RowLayout {Layout.fillWidth:true;spacing:Theme.gap/2
                    IconButton {visible:!narrow;iconName:"arrow_back";label:I18n.t("后退");enabled:!!(activeBrowser && activeBrowser.canGoBack);onClicked:if(activeBrowser)activeBrowser.goBack()}
                    IconButton {visible:!narrow;iconName:"arrow_forward";label:I18n.t("前进");enabled:!!(activeBrowser && activeBrowser.canGoForward);onClicked:if(activeBrowser)activeBrowser.goForward()}
                    IconButton {iconName:activeBrowser && activeBrowser.loading?"close":"refresh";label:activeBrowser && activeBrowser.loading?I18n.t("停止加载"):I18n.t("刷新");enabled:!!activeBrowser;onClicked:{if(activeBrowser.loading)activeBrowser.stop();else activeBrowser.reload()}}
                    IconButton {objectName:"browserWheelToggle";iconName:"gamepad";label:I18n.t("网页方向轮盘");Accessible.name:I18n.t(win.browserWheelEnabled?"关闭网页方向轮盘":"打开网页方向轮盘");filled:win.browserWheelEnabled;enabled:!!win.activeBrowser;onClicked:win.browserWheelEnabled=!win.browserWheelEnabled}
                    CarField {id:location;objectName:"browserAddressField";Layout.fillWidth:true;Layout.minimumWidth:Math.max(48,Theme.hit*0.75);Layout.minimumHeight:Theme.hit;Layout.preferredHeight:Theme.hit;implicitWidth:0
                        text:activeBrowser?activeBrowser.url.toString():defaultBrowserUrl;placeholderText:"";onAccepted:navigateBrowser(text)}
                    IconButton {visible:!win.compactBrowserToolbar;iconName:"arrow_forward";label:I18n.t("前往");onClicked:navigateBrowser(location.text)}
                        IconButton {iconName:"tune";label:I18n.t("浏览器工具");onClicked:browserTools.open()
                        Menu {
                            id:browserTools;objectName:"browserToolsMenu"
                             width:Math.min(320,Math.max(296,win.width-24))
                             padding:8
                             delegate:MenuItem {
                                 implicitHeight:48
                                 icon.width:24;icon.height:24
                             }
                             background:Rectangle {color:Theme.surfaceContainerHigh;radius:Theme.shapeMedium;border.width:1;border.color:Theme.outlineVariant}
                            // Back/forward and bookmark are promoted to the
                            // round shortcut row for compact, no-duplication UI.
                            MenuItem {
                                id:browserQuickActions;objectName:"browserQuickActions"
                                text:"";implicitHeight:64
                                Accessible.name:I18n.t("浏览器快捷操作")
                                background:Item{}
                                contentItem:Item {
                                    Row {
                                        id:browserQuickActionRow;objectName:"browserQuickActionRow"
                                        anchors.centerIn:parent;spacing:8
                                        ToolButton {
                                            objectName:"browserQuickBack";width:48;height:48;padding:0
                                            enabled:!!(activeBrowser&&activeBrowser.canGoBack)
                                            icon.source:systemTools.monochromeIcon("arrow_back",true);icon.width:24;icon.height:24
                                            Accessible.name:I18n.t("后退")
                                            background:Rectangle {radius:24;color:parent.enabled?(parent.hovered?"#3a3f48":"#171a20"):"#3b4048"}
                                            onClicked:{browserTools.close();if(activeBrowser)activeBrowser.goBack()}
                                        }
                                        ToolButton {
                                            objectName:"browserQuickForward";width:48;height:48;padding:0
                                            enabled:!!(activeBrowser&&activeBrowser.canGoForward)
                                            icon.source:systemTools.monochromeIcon("arrow_forward",true);icon.width:24;icon.height:24
                                            Accessible.name:I18n.t("前进")
                                            background:Rectangle {radius:24;color:parent.enabled?(parent.hovered?"#3a3f48":"#171a20"):"#3b4048"}
                                            onClicked:{browserTools.close();if(activeBrowser)activeBrowser.goForward()}
                                        }
                                        ToolButton {
                                            objectName:"browserQuickBookmark";width:48;height:48;padding:0
                                            enabled:!!activeBrowser
                                            icon.source:systemTools.monochromeIcon("bookmark",true);icon.width:24;icon.height:24
                                            Accessible.name:I18n.t("收藏当前网页")
                                            background:Rectangle {radius:24;color:parent.hovered?"#3a3f48":"#171a20"}
                                            onClicked:{win.rememberCurrentBrowser();browserTools.close()}
                                        }
                                        ToolButton {
                                            objectName:"browserQuickCloseTab";width:48;height:48;padding:0
                                            enabled:tabs.count>1
                                            icon.source:systemTools.monochromeIcon("close",true);icon.width:24;icon.height:24
                                            Accessible.name:I18n.t("关闭当前标签页")
                                            background:Rectangle {radius:24;color:parent.enabled?(parent.hovered?"#3a3f48":"#171a20"):"#3b4048"}
                                            onClicked:{browserTools.close();win.closeBrowserTab()}
                                        }
                                        ToolButton {
                                            objectName:"browserQuickReload";width:48;height:48;padding:0
                                            enabled:!!activeBrowser
                                            icon.source:systemTools.monochromeIcon(activeBrowser&&activeBrowser.loading?"close":"refresh",true);icon.width:24;icon.height:24
                                            Accessible.name:activeBrowser&&activeBrowser.loading?I18n.t("停止加载"):I18n.t("刷新")
                                            background:Rectangle {radius:24;color:parent.enabled?(parent.hovered?"#3a3f48":"#171a20"):"#3b4048"}
                                            onClicked:{if(activeBrowser){if(activeBrowser.loading)activeBrowser.stop();else activeBrowser.reload()}browserTools.close()}
                                        }
                                    }
                                }
                            }
                            MenuSeparator {contentItem:Rectangle {implicitHeight:1;color:"#484d55"}}
                            MenuItem {objectName:"browserManageBookmarks";text:I18n.t("管理书签（")+browserBookmarks.length+"）";implicitHeight:48;icon.width:24;icon.height:24;icon.source:systemTools.monochromeIcon("bookmark",true);onTriggered:bookmarkDialog.open()}
                            MenuItem {
                                id:browserMoreMenuButton;objectName:"browserMoreMenuButton"
                                text:I18n.t("更多浏览器工具");implicitHeight:48
                                icon.width:24;icon.height:24;icon.source:systemTools.monochromeIcon("more_horiz",true)
                                onTriggered:{
                                    const point=mapToItem(Overlay.overlay,0,0)
                                    const menuWidth=browserMoreMenu.width
                                    browserMoreMenu.x=point.x+width+menuWidth<=win.width?point.x+width:Math.max(8,point.x-menuWidth)
                                    browserMoreMenu.y=Math.max(8,Math.min(point.y,win.height-browserMoreMenu.implicitHeight-8))
                                    browserTools.close()
                                    Qt.callLater(browserMoreMenu.open)
                                }
                            }
                            MenuSeparator {contentItem:Rectangle {implicitHeight:1;color:"#484d55"}}
                            MenuItem {
                                id:browserZoomControls;objectName:"browserZoomControls"
                                enabled:!!activeBrowser;text:"";implicitHeight:56
                                Accessible.name:I18n.t("缩放网页")
                                background:Item{}
                                contentItem:RowLayout {
                                    spacing:0
                                    ToolButton {
                                        id:browserZoomOut;objectName:"browserZoomOut";Layout.preferredWidth:48;Layout.preferredHeight:48;padding:0
                                        icon.source:systemTools.monochromeIcon("zoom_out",true);icon.width:24;icon.height:24
                                        Accessible.name:I18n.t("缩小网页")
                                        onClicked:if(activeBrowser)activeBrowser.zoomFactor=Math.max(1,activeBrowser.zoomFactor-0.2)
                                    }
                                    ToolButton {
                                        id:browserZoomIn;objectName:"browserZoomIn";Layout.preferredWidth:48;Layout.preferredHeight:48;padding:0
                                        icon.source:systemTools.monochromeIcon("zoom_in",true);icon.width:24;icon.height:24
                                        Accessible.name:I18n.t("放大网页")
                                        onClicked:if(activeBrowser)activeBrowser.zoomFactor=Math.min(3,activeBrowser.zoomFactor+0.2)
                                    }
                                    Label {id:browserZoomPercent;objectName:"browserZoomPercent"
                                        text:activeBrowser?Math.round(activeBrowser.zoomFactor*100)+"%":"100%"
                                        Layout.preferredWidth:56;horizontalAlignment:Text.AlignHCenter
                                        Accessible.name:I18n.t("当前网页缩放比例")+" "+text
                                    }
                                }
                            }
                        }
                    }
                    Menu {
                        id:browserMoreMenu;objectName:"browserMoreMenu";parent:Overlay.overlay
                        width:Math.min(320,win.width-24);padding:8;margins:8
                        background:Rectangle {color:Theme.surfaceContainerHigh;radius:Theme.shapeMedium;border.width:1;border.color:Theme.outlineVariant}
                        delegate:MenuItem {implicitHeight:48;icon.width:24;icon.height:24}
                        MenuItem {objectName:"browserHistoryAction";text:I18n.t("浏览历史");icon.source:systemTools.monochromeIcon("history",true);onTriggered:browserHistoryDialog.open()}
                        MenuItem {objectName:"browserDownloadsAction";text:I18n.t("下载管理");icon.source:systemTools.monochromeIcon("download",true);onTriggered:browserDownloadsDialog.open()}
                        MenuItem {objectName:"browserPrintPdfAction";text:I18n.t("保存为 PDF");icon.source:systemTools.monochromeIcon("print",true);enabled:!!activeBrowser;onTriggered:{browserPdfPath.text=viperBrowser.downloadDirectory()+"/webpage-"+Date.now()+".pdf";browserPdfDialog.open()}}
                        MenuItem {objectName:"browserPrivateMode";text:I18n.t("新建无痕标签");icon.source:systemTools.monochromeIcon("visibility_off",true);enabled:tabs.count<8;onTriggered:{tabs.append({address:viperBrowser.newTabUrl(),privateMode:true});browserTabs.currentIndex=tabs.count-1}}
                        MenuItem {objectName:"browserUpdateFilters";text:I18n.t("更新广告过滤规则");icon.source:systemTools.monochromeIcon("sync",true);onTriggered:viperBrowser.updateSubscriptions()}
                        MenuItem {objectName:"browserAdvancedSettings";text:I18n.t("浏览器设置与扩展");icon.source:systemTools.monochromeIcon("settings",true);onTriggered:browserConfigDialog.open()}
                        MenuItem {objectName:"browserPopupSetting";text:I18n.t("允许弹出窗口");checkable:true;checked:viperBrowser.javascriptPopupsEnabled;onTriggered:viperBrowser.setJavascriptPopupsEnabled(checked)}
                    }
                }
                CarText {visible:browserStatus.indexOf(I18n.t("加载失败"))===0;text:browserStatus;color:Theme.warning;subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                Flow { Layout.fillWidth:true; spacing:Theme.gap
                    Repeater { model:tabs; CarButton {
                        required property int index;required property var model;text:model.pageTitle || (I18n.t("网页 ")+(index+1));width:Math.max(48,Math.min(160*uiScale,Math.max(92*uiScale,(browserColumn.width-Theme.gap*(tabs.count+1)-Theme.hit*2)/Math.max(1,tabs.count))));height:Theme.hit;checked:browserTabs.currentIndex===index
                        onClicked:browserTabs.currentIndex=index
                    } }
                    IconButton {iconName:"add";label:I18n.t("新标签页");enabled:tabs.count<8;onClicked:{tabs.append({address:viperBrowser.newTabUrl(),privateMode:false});browserTabs.currentIndex=tabs.count-1}
                        contentItem:Image {source:"qrc:/icons/browser-new-tab.svg";sourceSize.width:48;sourceSize.height:48;anchors.centerIn:parent;fillMode:Image.PreserveAspectFit}
                    }
                    IconButton {iconName:"close";label:I18n.t("关闭当前标签页");enabled:tabs.count>1;onClicked:{let i=browserTabs.currentIndex;browserTabs.currentIndex=0;tabs.remove(i)}}
                }
                ProgressBar {
                    objectName:"browserWheelInjectionProgress"
                    Layout.fillWidth:true
                    Layout.minimumHeight:4 * uiScale
                    Layout.preferredHeight:4 * uiScale
                    Layout.maximumHeight:4 * uiScale
                    visible:browserWheel.preparing
                    indeterminate:!!win.activeBrowser && (win.activeBrowser.loading || browserWheel.pending)
                    value:browserWheel.trackingInstalled ? 1 : 0
                    Accessible.name:I18n.t("正在准备网页滚动轮盘")
                }
                QtObject {
                    id:browserTabs
                    property int currentIndex:0
                    onCurrentIndexChanged: {
                        win.browserViewGeneration++
                        // StackLayout can clamp its currentIndex while a
                        // Repeater row is being added, which removes the
                        // declarative binding. Re-apply the selected tab so
                        // activeBrowser points at the visible WebEngineView.
                        if (browserViewLoader.item && browserViewLoader.item.currentIndex!==currentIndex)
                            browserViewLoader.item.currentIndex=currentIndex
                        win.refreshActiveBrowser()
                        Qt.callLater(function(){win.refreshActiveBrowser()})
                        if (currentIndex>=0 && currentIndex<tabs.count) {
                            location.text=tabs.get(currentIndex).address
                            browserStatus=""
                        }
                    }
                }
                ListModel { id:tabs; ListElement { address:"https://baidu.com";pageTitle:"百度";privateMode:false } }
                // 懒加载：只有第一次打开浏览器（win.browserLoaded）才创建
                // WebEngineView，避免启动时就拉起 QtWebEngineProcess。
                // 联网权限：入口不拒绝（否则"请求被拦"这条路径根本走不到），
                // 改成能打开、但所有请求被 RequestInterceptor 就地取消，这里如实说明。
                CarText {
                    objectName:"browserNetworkOff"
                    Layout.fillWidth:true
                    visible: win.section===2 && !(networkGate.enabled && networkGate.featureEnabled("browser"))
                    color:Theme.warning
                    wrapMode:Text.Wrap
                    text:I18n.t("联网已关闭：浏览器不会发出任何请求。请到设置 → 联网权限里打开浏览器联网。")
                }
                CarText {
                    objectName:"browserHttpWarning"
                    Layout.fillWidth:true
                    visible: win.section===2 && !!activeBrowser
                             && activeBrowser.url.toString().toLowerCase().startsWith("http://")
                    color:Theme.warning
                    wrapMode:Text.Wrap
                    text:I18n.t("不安全：此网页使用明文 HTTP，内容可能被窃听或篡改。")
                }
                // 浏览器加载进度条：首次打开/换页时给出即时反馈，
                // 避免 WebEngine 懒加载期间“点了没反应”。
                Item {
                    objectName:"browserLoadProgress"
                    Layout.fillWidth:true
                    Layout.preferredHeight: 3 * win.uiScale
                    visible: !!win.activeBrowser && win.activeBrowser.loading
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height
                        width: parent.width * Math.max(0.02, win.activeBrowser ? win.activeBrowser.loadProgress : 0)
                        radius: height / 2
                        color: Theme.accent
                    }
                }
                Loader {
                    id:browserViewLoader
                    objectName:"browserViewLoader"
                    Layout.fillWidth:true; Layout.fillHeight:true;Layout.minimumHeight:0
                    active:win.browserLoaded
                    onLoaded:win.refreshActiveBrowser()
                    sourceComponent:Component {
                StackLayout {
                    anchors.fill:parent
                    currentIndex:browserTabs.currentIndex
                    Repeater {
                        id:browserRepeater
                        model:tabs
                        onItemAdded:function(index,item) { win.browserViewGeneration++;Qt.callLater(function(){win.refreshActiveBrowser()}) }
                        onItemRemoved:function(index,item) { win.browserViewGeneration++;Qt.callLater(function(){win.refreshActiveBrowser()}) }
                        WebEngineView {
                            id:browserWebViewItem
                            objectName:"browserWebView"
                            Layout.fillWidth:true; Layout.fillHeight:true
                            required property string address;required property int index;url:address;zoomFactor:1.0
                            required property bool privateMode
                            profile:privateMode?terminalPrivateProfile:terminalViperProfile
                            activeFocusOnPress:true
                            settings.javascriptEnabled:viperBrowser.preferences.javascript
                            settings.javascriptCanOpenWindows:viperBrowser.preferences.popups
                            settings.autoLoadImages:viperBrowser.preferences.images
                            DragHandler {
                                id:browserTouchScroll;objectName:"browserTouchScrollFallback"
                                target:null;acceptedDevices:PointerDevice.TouchScreen
                                // WebEngine takes the touch stream for its own
                                // gesture handling on some backends. Keep this
                                // fallback able to take over so a swipe still
                                // scrolls even when Chromium declines it.
                                grabPermissions:PointerHandler.CanTakeOverFromAnything|PointerHandler.ApprovesTakeOverByAnything
                                property real previousTranslationY:0
                                onActiveChanged:previousTranslationY=translation.y
                                onTranslationChanged:function() {
                                    if(!active)return
                                    const delta=translation.y-previousTranslationY
                                    previousTranslationY=translation.y
                                    win.browserTouchDragDistance+=delta
                                    if(Math.abs(delta)>0.1)
                                        browserWebViewItem.runJavaScript("window.scrollBy(0,"+(-delta)+")")
                                }
                            }
                            onTitleChanged:if(index>=0 && index<tabs.count)tabs.setProperty(index,"pageTitle",title)
                            onNavigationRequested:function(request) {
                                if (index>=0 && index<tabs.count && request.url.toString()!==tabs.get(index).address)
                                    tabs.setProperty(index,"address",request.url.toString())
                                if (index===browserTabs.currentIndex) { location.text=request.url.toString(); browserStatus=I18n.t("正在加载") }
                                request.accept()
                            }
                            onNewWindowRequested:function(request) {
                                const target=request.requestedUrl.toString()
                                // The audit fixture's target=_blank link may be
                                // blocked by the network gate after this signal
                                // opens its tab; record the activation itself.
                                if(target.indexOf("touch-link.example")>=0)browserTouchLinkPassed=true
                                if (tabs.count>=8) {
                                    request.openIn(browserWebViewItem)
                                    return
                                }
                                tabs.append({address:target || viperBrowser.newTabUrl(),privateMode:privateMode})
                                browserTabs.currentIndex=tabs.count-1
                                const newView=browserRepeater.itemAt(tabs.count-1)
                                if(newView)request.openIn(newView)
                                else browserStatus=I18n.t("加载失败：")+I18n.t("无法打开此网页")
                            }
                            onAuthenticationDialogRequested:function(request) {
                                win.pendingBrowserAuth={view:browserWebViewItem,request:request}
                                browserAuthDialog.url=request.url.toString();browserAuthDialog.realm=request.realm;browserAuthDialog.open()
                            }
                            onFeaturePermissionRequested:function(origin,feature) {
                                win.pendingBrowserPermission={view:browserWebViewItem,origin:origin,feature:feature}
                                browserPermissionDialog.origin=origin.toString();browserPermissionDialog.feature=feature;browserPermissionDialog.open()
                            }
                            property string filterInjectedUrl:""
                            onUrlChanged: {
                                if(filterInjectedUrl!==url.toString())filterInjectedUrl=""
                                if(url.host==="touch-link.example")browserTouchLinkPassed=true
                                if(index>=0 && index<tabs.count && tabs.get(index).address!==url.toString())tabs.setProperty(index,"address",url.toString())
                                if(index===browserTabs.currentIndex)location.text=url.toString()
                            }
                            onLoadProgressChanged: {
                                if(loadProgress<22 || !url || !url.host || filterInjectedUrl===url.toString())return
                                filterInjectedUrl=url.toString()
                                viperBrowser.requestAdBlockData(url,index)
                            }
                            onLoadingChanged:function(request) {
                                if (index===browserTabs.currentIndex) {
                                    if (request.status===WebEngineView.LoadStartedStatus) browserStatus=I18n.t("正在加载")
                                    else if (request.status===WebEngineView.LoadSucceededStatus) {browserStatus="";viperBrowser.recordVisit(url,title)}
                                    else if (request.status===WebEngineView.LoadFailedStatus) browserStatus=I18n.t("加载失败：")+(request.errorString || I18n.t("无法打开此网页"))
                                }
                                if(browserTestRunning && request.status===WebEngineView.LoadSucceededStatus && title==="Local terminal test")
                                    runJavaScript("21 * 2",function(value){browserTestPassed=value===42 && tabs.count===2;browserTestRunning=false})
                                if(request.status===WebEngineView.LoadSucceededStatus) {
                                    runJavaScript("document.documentElement.style.touchAction='pan-x pan-y'; if(document.body) document.body.style.touchAction='pan-x pan-y';")
                                }
                            }
                            onPdfPrintingFinished:function(filePath,success) {
                                if(index===browserTabs.currentIndex)browserStatus=success?I18n.t("PDF 已保存：")+filePath:I18n.t("PDF 保存失败")
                            }
                        }
                    }
                }
                    }
                }
            }
            BrowserWheel {
                id: browserWheel
                objectName:"browserWheel"
                parent: browserFlick
                width: 184 * uiScale
                height: width
                readonly property point pageOrigin: targetView ? targetView.mapToItem(browserFlick,0,0) : Qt.point(0,0)
                x: pageOrigin.x + (targetView ? targetView.width : 0) - width - 16 * uiScale
                y: pageOrigin.y + (targetView ? targetView.height : 0) - height - 16 * uiScale
                targetView: win.activeBrowser
                switchedOn: win.browserWheelEnabled && win.section===2 && browserFlick.visible
                language: systemTools.uiLanguage
                translate: function(text) { return I18n.t(text) }
                z: 100
            }
        }
        Flickable {
            id:filesFlick; objectName:"filesPage"; clip:true; contentWidth:width; contentHeight:height;interactive:false
            readonly property bool compact:width<500*uiScale || height<400*uiScale
            Item { id:filesColumn; width:filesFlick.width; height:filesFlick.height
                Rectangle { id:filesSidebar;visible:filesFlick.width>500*uiScale;anchors.left:parent.left;anchors.top:parent.top;anchors.bottom:parent.bottom;width:Math.min(220*uiScale,filesFlick.width*0.28);color:Theme.surface
                    ScrollView {id:placesScroll;anchors.fill:parent;anchors.margins:Theme.gap;clip:true;contentWidth:availableWidth
                    ColumnLayout { width:placesScroll.availableWidth; spacing:3
                        CarText {visible:win.fileRemovableDevices.length>0;text:I18n.t("USB 设备");subdued:true;Layout.fillWidth:true}
                        Repeater {model:win.fileRemovableDevices
                            Button {required property var modelData;objectName:"usbDeviceButton";Layout.fillWidth:true;Layout.minimumHeight:48;Layout.preferredHeight:48;Layout.maximumHeight:48;leftPadding:4;rightPadding:4;topPadding:4;bottomPadding:4;topInset:0;bottomInset:0
                                Accessible.name:modelData.name+"，"+(modelData.mounted?I18n.t("已挂载"):I18n.t("点击挂载"))
                                background:Rectangle {radius:Theme.shapeSmall;color:folder===modelData.location||folder.indexOf(modelData.location+"/")===0?Theme.raised:"transparent";border.width:parent.activeFocus?2:0;border.color:Theme.accent}
                                contentItem:RowLayout {spacing:8
                                    MaterialIcon {name:"storage";Layout.preferredWidth:24*uiScale;Layout.preferredHeight:24*uiScale}
                                    ColumnLayout {Layout.fillWidth:true;spacing:0
                                        CarText {text:modelData.name;fontPixelSize:16;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                        CarText {text:modelData.mounted?I18n.t("已挂载"):I18n.t("点击挂载");subdued:true;fontPixelSize:12;Layout.fillWidth:true;maximumLineCount:1}
                                    }
                                }
                                onClicked:systemTools.openRemovableDevice(modelData.id)
                            }
                        }
                        CarText { text:I18n.t("位置"); subdued:true; Layout.fillWidth:true }
                        Repeater {model:[{label:I18n.t("最近使用"),icon:"refresh",location:"recent"},{label:I18n.t("主目录"),icon:"folder",location:"home"},{label:I18n.t("文档"),icon:"description",location:"documents"},{label:I18n.t("下载"),icon:"storage",location:"downloads"}]
                            Button {id:placeButton;required property var modelData;property bool auditControl:true
                                Layout.fillWidth:true;Layout.preferredHeight:48;Layout.minimumHeight:48;font.pixelSize:16;padding:4;leftPadding:4;rightPadding:4
                                Accessible.name:modelData.label
                                checked:modelData.location==="recent"?filesRecent:!filesRecent && folder===(modelData.location==="home"?"":systemTools.fileLocation(modelData.location))
                                background:Rectangle {radius:Theme.shapeSmall;color:placeButton.down?Theme.pressed:placeButton.checked?Theme.raised:"transparent";border.width:placeButton.activeFocus?2:0;border.color:Theme.accent}
                                contentItem:RowLayout {spacing:Theme.gap/2
                                    MaterialIcon {name:placeButton.modelData.icon;Layout.preferredWidth:24*uiScale;Layout.preferredHeight:24*uiScale}
                                    Text {text:placeButton.modelData.label;font:placeButton.font;color:Theme.foreground;Layout.fillWidth:true;elide:Text.ElideRight}
                                }
                                onClicked:if(modelData.location==="recent"){filesRecent=true;fileSelection="";fileFilter="";refreshFiles()}else navigateFiles(modelData.location==="home"?"":systemTools.fileLocation(modelData.location))
                            }
                        }
                    }
                    }
                }
                ColumnLayout { anchors.fill:parent;anchors.margins:filesFlick.compact?Theme.gap/2:Theme.gap;anchors.leftMargin:filesSidebar.visible?filesSidebar.width+Theme.gap:filesFlick.compact?Theme.gap/2:Theme.gap;spacing:filesFlick.compact?Theme.gap/2:Theme.gap
                    Flow { Layout.fillWidth:true; spacing:Theme.gap/2
                        IconButton { visible:!filesFlick.compact;iconName:"arrow_back"; label:I18n.t("后退"); enabled:fileHistoryIndex>0; onClicked:{fileHistoryIndex--;navigateFiles(fileHistory[fileHistoryIndex],false)} }
                        IconButton { visible:!filesFlick.compact;iconName:"arrow_forward"; label:I18n.t("前进"); enabled:fileHistoryIndex<fileHistory.length-1; onClicked:{fileHistoryIndex++;navigateFiles(fileHistory[fileHistoryIndex],false)} }
                         IconButton { visible:!filesFlick.compact;iconName:"refresh"; label:I18n.t("刷新"); onClicked:refreshFiles() }
                         IconButton {iconName:"search";label:I18n.t("搜索文件");onClicked:{fileSearchVisible=!fileSearchVisible;if(fileSearchVisible)Qt.callLater(function(){fileSearch.forceActiveFocus()})}}
                        IconButton { iconName:fileGridView?"view_list":"apps"; label:fileGridView?I18n.t("列表视图"):I18n.t("网格视图"); onClicked:fileGridView=!fileGridView }
                        IconButton { iconName:"tune";label:I18n.t("文件操作");onClicked:fileActions.open()
                            Menu {id:fileActions
                                MenuItem {text:I18n.t("后退");enabled:fileHistoryIndex>0;onTriggered:{fileHistoryIndex--;navigateFiles(fileHistory[fileHistoryIndex],false)}}
                                MenuItem {text:I18n.t("前进");enabled:fileHistoryIndex<fileHistory.length-1;onTriggered:{fileHistoryIndex++;navigateFiles(fileHistory[fileHistoryIndex],false)}}
                                MenuItem {text:I18n.t("刷新");onTriggered:refreshFiles()}
                                MenuItem {text:I18n.t("主目录");onTriggered:navigateFiles("")}
                                MenuItem {text:I18n.t("上一级");enabled:!!folder && !filesRecent;onTriggered:navigateFiles(fileParent())}
                                MenuItem {text:I18n.t("最近使用");onTriggered:{filesRecent=true;fileSelection="";refreshFiles()}}
                                MenuSeparator {}
                                MenuItem {text:I18n.t("新建文件");enabled:!filesRecent;onTriggered:requestFileOperation("newFile")}
                                MenuItem {text:I18n.t("新建文件夹");enabled:!filesRecent;onTriggered:requestFileOperation("newFolder")}
                                MenuItem {text:I18n.t("打开");enabled:!!fileSelection;onTriggered:{const row=fileRows.find(function(r){return (r.relative||r.name)===fileSelection});if(row)openFileRow(row)}}
                                MenuItem {text:I18n.t("重命名");enabled:!!fileSelection && !filesRecent;onTriggered:requestFileOperation("rename")}
                                MenuItem {text:I18n.t("删除");enabled:!!fileSelection;onTriggered:requestFileOperation("delete")}
                                MenuItem {text:I18n.t("设为壁纸");enabled:!!fileSelection;onTriggered:{const row=fileRows.find(function(r){return (r.relative||r.name)===fileSelection});if(row && !row.directory)systemTools.setFileWallpaper(row.relative || ((folder?folder+"/":"")+row.name))}}
                            }
                        }
                    }
                    CarText {Layout.fillWidth:true;text:filesRecent?I18n.t("最近使用"):systemTools.fileDisplayPath(folder);elide:Text.ElideMiddle;maximumLineCount:1;subdued:true}
                     CarField { id:fileSearch;objectName:"fileSearchField";visible:fileSearchVisible;Layout.fillWidth:true; Layout.minimumHeight:Theme.hit; placeholderText:I18n.t("搜索文件"); text:fileFilter; onTextChanged:if(fileFilter!==text)fileFilter=text }
                    CarText { visible:filteredFileRows.length===0; text:fileFilter?I18n.t("没有匹配的文件"):filesRecent?I18n.t("暂无最近使用的文件"):I18n.t("当前文件夹为空"); subdued:true; Layout.fillWidth:true }
                    ScrollView {id:fileScroll;objectName:"fileScroll";Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumWidth:0;Layout.minimumHeight:48;implicitWidth:0;contentWidth:availableWidth;contentHeight:fileContent.height;clip:true
                        ScrollBar.vertical: ScrollBar {
                            id:fileVerticalScrollBar;parent:fileScroll
                            anchors.top:fileScroll.top;anchors.bottom:fileScroll.bottom;anchors.right:fileScroll.right
                            policy:ScrollBar.AsNeeded
                        }
                        ScrollBar.horizontal: ScrollBar {policy:ScrollBar.AlwaysOff}
                    Column {id:fileContent;width:fileScroll.availableWidth
                        property real measuredContentHeight:fileGridView?fileGrid.implicitHeight:fileList.implicitHeight
                        height:measuredContentHeight
                    GridLayout { id:fileGrid;visible:fileGridView; width:fileScroll.availableWidth; columnSpacing:Theme.gap; rowSpacing:Theme.gap; columns:Math.max(1,Math.floor((width+Theme.gap)/(128*uiScale)))
                        Repeater { model:filteredFileRows
                            Item { required property var modelData; Layout.fillWidth:true; Layout.preferredWidth:112*uiScale; Layout.preferredHeight:136*uiScale
                                Column { anchors.fill:parent; spacing:8*uiScale
                                FileThumbnail { anchors.horizontalCenter:parent.horizontalCenter; entry:modelData; relative:modelData.relative || ((folder?folder+"/":"")+modelData.name); fallback:fileIcon(modelData); width:52*uiScale; height:52*uiScale }
                                    Text { width:parent.width; text:modelData.name; color:Theme.foreground; font.pointSize:Theme.body; horizontalAlignment:Text.AlignHCenter; wrapMode:Text.Wrap;elide:Text.ElideMiddle; maximumLineCount:2 }
                                }
                                Rectangle { anchors.fill:parent; z:-1; radius:Theme.shapeSmall; color:fileSelection===(modelData.relative||modelData.name)?Theme.raised:"transparent" }
                                activeFocusOnTab:true
                                Keys.onReturnPressed:openFileRow(modelData)
                                Accessible.role:Accessible.Button;Accessible.name:modelData.name;Accessible.onPressAction:openFileRow(modelData)
                                TapHandler {gesturePolicy:TapHandler.DragThreshold;acceptedDevices:PointerDevice.Mouse|PointerDevice.TouchScreen;onTapped:win.activateFileEntry(modelData)}
                            }
                        }
                    }
                    ColumnLayout { id:fileList;visible:!fileGridView; width:fileScroll.availableWidth
                        Repeater { model:filteredFileRows
                            Rectangle { required property var modelData; color:fileSelection===(modelData.relative||modelData.name)?Theme.raised:"transparent"; Layout.fillWidth:true; Layout.preferredHeight:Theme.hit
                                RowLayout { anchors.fill:parent; anchors.margins:Theme.gap/2; spacing:Theme.gap
                                    FileThumbnail { entry:modelData; relative:modelData.relative || ((folder?folder+"/":"")+modelData.name); fallback:fileIcon(modelData); Layout.preferredWidth:40*uiScale; Layout.preferredHeight:40*uiScale }
                                    Text { text:modelData.name; color:Theme.foreground; font.pointSize:Theme.body; Layout.fillWidth:true; elide:Text.ElideMiddle }
                                    Text { visible:filesFlick.width>600*uiScale;text:modelData.directory?I18n.t("文件夹"):(modelData.bytes+" B"); color:Theme.secondary; font.pointSize:Theme.body; }
                                }
                                activeFocusOnTab:true;Keys.onReturnPressed:openFileRow(modelData)
                                TapHandler {gesturePolicy:TapHandler.DragThreshold;acceptedDevices:PointerDevice.Mouse|PointerDevice.TouchScreen;onTapped:win.activateFileEntry(modelData)}
                            }
                        }
                    }
                    }
                    }
                    CarText {visible:!filesFlick.compact;text:filteredFileRows.length+I18n.t(" 项")+(fileSelection?I18n.t("，已选择 ")+fileSelection:"");subdued:true;Layout.fillWidth:true;elide:Text.ElideMiddle;maximumLineCount:1}
                }
            }
        }
        Loader {
            id:settingsPageLoader
            // StackLayout 自己管理子项几何；这里不能再 anchors.fill（Qt 6.5
            // 会报 "anchors on an item managed by a layout"，并留下未定义布局）。
            Layout.fillWidth:true
            Layout.fillHeight:true
            // Settings has many SettingsGroup/wrapped rows. Building them while
            // this StackLayout page is hidden at ~1px makes Qt 6.5 abort a
            // polish loop; create the page only while it is open.
            active:win.section===4 && win.phase!=="home"
            // 设置页组件很多，同步创建会把主线程占满；异步加载让
            // 页面先出现、内容随后补齐（不涉及渲染/模糊）。
            asynchronous:true
            sourceComponent:Component {
        Item {
            // 主页与二级页在同一层：分类页盖在主页上，设置页关闭时整层一起卸载。
            Component.onCompleted: win.settingsSection = -1

            Flickable {
                id:settingsFlick;objectName:"settingsPage";clip:true;anchors.fill:parent
                contentWidth:width;contentHeight:settingsColumn.implicitHeight
                // 二级页盖在上面时禁用下层：点击空白处不能穿透。
                enabled:!win.aboutDeviceOpen && !win.networkPermissionsOpen && win.settingsSection<0
                boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id:settingsColumn;width:settingsFlick.width;spacing:Theme.gap

                    RowLayout {
                        Layout.fillWidth:true;spacing:Theme.gap
                        CarField {id:settingsSearch;plainHint:true;Layout.fillWidth:true;leftPadding:52*uiScale
                            placeholderText:systemTools.uiLanguage==="en"?"Search settings":I18n.t("搜索设置")
                            text:settingsQuery;onTextChanged:settingsQuery=text
                            // 点击输入框才弹键盘（CarField 的 TapHandler），关掉不会再自己弹回来。
                            onKeyboardRequested:screenKeyboard.show()
                            Component.onCompleted:win.keyboardAuditInput=settingsSearch
                            background:Rectangle {radius:Theme.shapeFull;color:Theme.surface;border.color:settingsSearch.activeFocus?Theme.accent:Theme.outline}
                            MaterialIcon {anchors.left:parent.left;anchors.leftMargin:Theme.gap;anchors.verticalCenter:parent.verticalCenter;width:Theme.icon;height:width;name:"search";light:true}
                        }
                        IconButton {iconName:"close";label:I18n.t("清除搜索");visible:settingsQuery!=="";onClicked:{settingsQuery="";settingsSearch.text=""}}
                    }
                    // 分类卡片：两列网格，同「用户与权限」的主页语言；
                    // 搜索词只过滤卡片，不改变每张卡片的内容。
                    GridLayout {
                        Layout.fillWidth:true
                        columns:2
                        rowSpacing:Theme.gap;columnSpacing:Theme.gap
                        Repeater {
                            model:win.settingsCards
                            delegate: Rectangle {
                                id:settingsCard
                                required property var modelData
                                required property int index
                                Layout.fillWidth:true
                                Layout.preferredHeight:132*Theme.scaleFactor
                                visible:(!settingsQuery || modelData.match.test(settingsQuery))
                                        && (!modelData.adminOnly || sessionManager.isAdmin)
                                        && (!modelData.hideForGuest || !sessionManager.guestSession)
                                radius:Theme.shapeLarge
                                color:settingsCardMouse.containsMouse ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                                border.width:1
                                border.color:settingsCardMouse.containsMouse ? Theme.accent : Theme.outlineVariant

                                RowLayout {
                                    anchors.fill:parent;anchors.margins:Theme.gap;spacing:Theme.gap
                                    Rectangle {
                                        Layout.preferredWidth:48*Theme.scaleFactor;Layout.preferredHeight:width
                                        radius:width/2
                                        color:Qt.darker(settingsCard.modelData.color,2.1)
                                        border.color:Qt.lighter(settingsCard.modelData.color,1.15)
                                        MaterialIcon {anchors.centerIn:parent;width:25*Theme.scaleFactor;height:width;name:settingsCard.modelData.icon;light:true}
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth:true;spacing:4
                                        CarText {Layout.fillWidth:true;text:settingsCard.modelData.title;fontPixelSize:Theme.fontStrong;color:Theme.foreground;elide:Text.ElideRight}
                                        CarText {Layout.fillWidth:true;text:settingsCard.modelData.subtitle;fontPixelSize:Theme.fontCaption;color:Theme.outline;wrapMode:Text.WordWrap;maximumLineCount:2;elide:Text.ElideRight}
                                    }
                                    MaterialIcon {Layout.preferredWidth:Theme.icon;Layout.preferredHeight:Theme.icon;name:"chevron_right";light:true}
                                }
                                MouseArea {
                                    id:settingsCardMouse
                                    anchors.fill:parent
                                    hoverEnabled:true
                                    onClicked:{
                                        // 开发者选项 / 关于本机：直接打开它们自己的右滑页，
                                        // 不再先进一个只有「打开…」按钮的中间页。
                                        if (settingsCard.modelData.action==="developer") { win.developerPanelOpen=true; return }
                                        if (settingsCard.modelData.action==="about") { win.aboutDeviceOpen=true; return }
                                        win.settingsSection=settingsCard.index
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 分类二级页：240ms 从右侧滑入（同开发者选项），页内仍是原来的 SettingsGroup。
            RightSlidePage {
                id:settingsDetail
                objectName:"settingsDetail"
                width:parent?parent.width:0
                height:parent?parent.height:0
                z:40
                open:win.settingsSection>=0
                onCloseRequested:win.settingsSection=-1

                Rectangle {anchors.fill:parent;color:Theme.background}

                // 页内唯一的主标题。两个彩蛋的触发点都移到这里：仍是连点 5 次，
                // 计数与回调转给原来的分组实例，彩蛋本身的逻辑和代码没有改。
                RowLayout {
                    id:settingsDetailHeader
                    x:Theme.margin;y:Theme.margin
                    width:Math.max(240,settingsDetail.width-Theme.margin*2)
                    spacing:Theme.gap/2
                    IconButton {objectName:"settingsDetailBack";iconName:"arrow_back";label:I18n.t("返回");onClicked:win.settingsSection=-1}
                    CarText {
                        id:settingsDetailTitle
                        Layout.fillWidth:true
                        heading:true
                        text:win.settingsSection>=0 && win.settingsSection<win.settingsCards.length
                             ? win.settingsCards[win.settingsSection].title : ""
                        elide:Text.ElideRight
                        MouseArea {
                            anchors.fill:parent
                            onClicked:{
                                if (win.settingsSection===0) personalizationGroup.registerTitleTap()
                                else if (win.settingsSection===5) settingsVoicePage.registerTitleTap()
                            }
                        }
                    }
                }

                // 普通分类：一个可滚动内容区，分组标题全部收起（只留主标题）。
                Flickable {
                    id:settingsDetailFlick
                    objectName:"settingsDetailFlick"
                    anchors.left:parent.left;anchors.right:parent.right
                    anchors.top:settingsDetailHeader.bottom;anchors.bottom:parent.bottom
                    anchors.margins:Theme.margin
                    anchors.topMargin:Theme.gap/2
                    visible:win.settingsSection!==5
                    contentWidth:width
                    contentHeight:settingsDetailColumn.implicitHeight
                    clip:true
                    boundsBehavior:Flickable.StopAtBounds
                    flickableDirection:Flickable.VerticalFlick
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    ColumnLayout {
                        id:settingsDetailColumn
                        width:settingsDetailFlick.width
                        spacing:Theme.gap

                        // ---- 0 显示与个性化（主标题连点 5 次 → 桌宠菜单）----
                        SettingsGroup {
                            id:personalizationGroup;objectName:"personalizationGroup"
                            Layout.fillWidth:true
                            visible:win.settingsSection===0
                            headerVisible:false
                            titleTapEnabled:true
                            onTitleTapped:{
                                const point=personalizationGroup.mapToItem(Overlay.overlay,0,0)
                                petEasterEggMenu.x=Math.max(12,Math.min(win.width-petEasterEggMenu.width-12,point.x))
                                petEasterEggMenu.y=Math.max(12,Math.min(win.contentItem.height-petEasterEggMenu.implicitHeight-12,point.y))
                                petEasterEggMenu.open()
                            }
                            iconName:"image";accentColor:"#ff9d37";title:systemTools.uiLanguage==="en"?"Display & personalization":I18n.t("显示与个性化");subtitle:systemTools.uiLanguage==="en"?"Wallpaper, cards and text":I18n.t("壁纸、应用卡片与屏幕文字")
                            CarText {text:I18n.t("壁纸，")+(systemTools.wallpaper.toString() || I18n.t("默认背景"));subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle}
                            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                                CarButton {objectName:"wallpaperChoose";text:I18n.t("选择图片");onClicked:wallpaperPicker.open()}
                                CarButton {text:I18n.t("恢复默认");enabled:systemTools.wallpaper.toString()!=="";onClicked:systemTools.setWallpaper("")}
                                CarButton {text:I18n.t("界面不透明度");onClicked:opacityDialog.open()}
                            }
                            CarText {text:I18n.t("界面比例，")+Math.round(textScale*100)+"%";subdued:true;Layout.fillWidth:true}
                            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                                CarButton {text:I18n.t("标准");checked:textScale===1;onClicked:{textScale=1;systemTools.setInterfaceScale(1)}}
                                CarButton {text:I18n.t("大字");checked:textScale===1.25;onClicked:{textScale=1.25;systemTools.setInterfaceScale(1.25)}}
                                CarButton {text:I18n.t("更大");checked:textScale===1.5;onClicked:{textScale=1.5;systemTools.setInterfaceScale(1.5)}}
                            }
                        }

                        // ---- 1 无障碍 ----
                        SettingsGroup {
                            Layout.fillWidth:true
                            visible:win.settingsSection===1
                            headerVisible:false
                            iconName:"accessibility_new";accentColor:"#ffb74d";title:I18n.t("无障碍");subtitle:I18n.t("大字号模式")
                            Switch {id:largeTextSwitch;objectName:"largeTextSwitch";Layout.fillWidth:true;text:I18n.t("大字号");font.pointSize:Theme.body;implicitHeight:Theme.hit
                                Binding {target:largeTextSwitch;property:"checked";value:systemTools.largeText}
                                onClicked:systemTools.setLargeText(!systemTools.largeText)
                            }
                            CarText {text:I18n.t("在界面缩放之上再放大一档字号；按钮热区不会小于 48 像素。");subdued:true;Layout.fillWidth:true;wrapMode:Text.Wrap}
                        }

                        // ---- 2 锁屏与安全 ----
                        LockSettings {
                            Layout.fillWidth:true
                            visible:win.settingsSection===2
                            headerVisible:false
                        }

                        // ---- 3 隐私与数据 ----
                        SettingsGroup {
                            Layout.fillWidth:true
                            visible:win.settingsSection===3
                            headerVisible:false
                            iconName:"shield";accentColor:"#4fd4a4";title:I18n.t("隐私与数据");subtitle:I18n.t("记录保留期限")
                            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                                Repeater {
                                    model:[{d:30,t:I18n.t("30 天")},{d:90,t:I18n.t("90 天")},{d:180,t:I18n.t("180 天")},{d:0,t:I18n.t("永久")}]
                                    CarButton {
                                        required property var modelData
                                        text:modelData.t
                                        checked:systemTools.retentionDays===modelData.d
                                        onClicked:systemTools.setRetentionDays(modelData.d)
                                    }
                                }
                            }
                            CarText {text:I18n.t("超过保留期限的健康记录会在下次登录时清理；本机删除不影响已拔出的 USB 备份。");subdued:true;Layout.fillWidth:true;wrapMode:Text.Wrap}
                        }

                        // ---- 4 语言 ----
                        SettingsGroup {
                            Layout.fillWidth:true
                            visible:win.settingsSection===4
                            headerVisible:false
                            iconName:"language";accentColor:"#27b7c5";title:I18n.t("语言 / Language");subtitle:I18n.t("切换终端界面显示语言")
                            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                                CarButton {text:I18n.t("简体中文");checked:systemTools.uiLanguage==="zh";onClicked:systemTools.setUiLanguage("zh")}
                                CarButton {objectName:"englishChoose";text:"English";checked:systemTools.uiLanguage==="en";onClicked:systemTools.setUiLanguage("en")}
                            }
                        }

                        // ---- 6 时间与报时 ----
                        TimeSyncSettings {
                            Layout.fillWidth:true
                            visible:win.settingsSection===6
                            headerVisible:false
                            timeSync:win.timeSyncBackend;alarmEngine:win.alarmBackend
                            clockFace:win.clockFace;timeFormat:win.timeFormat
                            onClockFaceRequested:function(mode){win.clockFace=mode}
                            onTimeFormatRequested:function(mode){win.timeFormat=mode}
                        }

                        // ---- 7 网络连接管理：联网总闸 + 各功能入口 + 热点开关 ----
                        NetworkPermissions {
                            Layout.fillWidth:true
                            visible:win.settingsSection===7
                            headerVisible:false
                            onManageRequested:{win.aboutDeviceOpen=false;win.networkPermissionsOpen=true}
                        }
                        SettingsGroup {
                            Layout.fillWidth:true
                            visible:win.settingsSection===7
                            headerVisible:false
                            iconName:"wifi";accentColor:"#35a9ff";title:I18n.t("热点");subtitle:I18n.t("本机热点开关与状态")
                            // 供电、接口地址等原始信息已移到开发者面板的 INTERFACES / POWER / HOTSPOT。
                            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                                CarButton {text:systemTools.hotspotBusy?I18n.t("处理中"):I18n.t("开启热点");enabled:!systemTools.hotspotBusy && (!systemTools.deviceStatus.hotspotKnown || !systemTools.deviceStatus.hotspotActive);onClicked:systemTools.hotspot(true)}
                                CarButton {text:I18n.t("关闭热点");enabled:!systemTools.hotspotBusy && (!systemTools.deviceStatus.hotspotKnown || systemTools.deviceStatus.hotspotActive);onClicked:systemTools.hotspot(false)}
                            }
                            CarText {text:I18n.t("热点，")+(!systemTools.deviceStatus.hotspotKnown?I18n.t("状态未知"):systemTools.deviceStatus.hotspotActive?I18n.t("已开启"):I18n.t("已关闭"));subdued:true;Layout.fillWidth:true}
                        }
                    }
                }

                // 5 语音音色：直接把语音页铺进来（自带滚动），不再有「打开语音音色」这一步。
                VoiceSettings {
                    id:settingsVoicePage
                    objectName:"settingsVoicePage"
                    anchors.left:parent.left;anchors.right:parent.right
                    anchors.top:settingsDetailHeader.bottom;anchors.bottom:parent.bottom
                    anchors.margins:Theme.margin
                    anchors.topMargin:Theme.gap/2
                    visible:win.settingsSection===5
                    active:win.settingsSection===5
                    hostWindow:win
                    uiScale:win.uiScale
                }
            }
        }
            }
        }
        Flickable {
            id:functionFlick;objectName:"functionPage";clip:true;contentWidth:width;contentHeight:functionColumn.implicitHeight
            boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            ColumnLayout {
                id:functionColumn;width:functionFlick.width;spacing:Theme.gap
                Flow {
                    id:moduleActions;Layout.fillWidth:true;spacing:Theme.gap
                    visible:activeActions.some(function(action){return ["open","start","stop","request_disconnect","drop_link","stale_data"].indexOf(action)<0})
                    Repeater {model:activeActions.filter(function(action){return ["start","stop","request_disconnect","drop_link","stale_data"].indexOf(action)<0});IconButton {
                        required property string modelData
                        // 模块声明的动作走 GUI 白名单入口（§8.4）：
                        // 未知动作仍显示原名，但参数范围由模块侧再校验。
                        iconName:({frame:"photo_camera",reset:"refresh",increment:"add",
                                   decrement:"remove",arm:"check",disarm:"link_off",
                                   mute:"volume_off",unmute:"volume_up"})[modelData] || "extension"
                        label:({frame:I18n.t("采集单帧"),reset:I18n.t("复位"),
                                increment:I18n.t("加一"),decrement:I18n.t("减一"),
                                arm:I18n.t("布防"),disarm:I18n.t("撤防"),
                                mute:I18n.t("静音"),unmute:I18n.t("取消静音")})[modelData] || modelData
                        visible:modelData!=="open";onClicked:connectionManager.action(activeSession,modelData)
                    }}
                }
                // §0.7：模块页由 modulePageHost 在独立 QQmlEngine 里创建，
                // 根对象以子项形式挂进这个容器，宿主对象不在它的 context 里。
                Item {
                    id:moduleLoader;objectName:"moduleFunctionLoader"
                    Layout.fillWidth:true
                    Layout.preferredHeight:Math.max(childrenRect.height, modulePageError.implicitHeight + Theme.gap * 2)
                    Component.onCompleted:modulePageHost.setContainer(moduleLoader)
                    Connections {
                        target:modulePageHost
                        function onPageChanged() {
                            if (modulePageHost.page)
                                modulePageHost.setContainer(moduleLoader)
                        }
                    }
                    // 模块页面加载失败时不能只留白：给出可读错误与出口。
                    Column {
                        id:modulePageError
                        anchors.centerIn: parent
                        width: Math.min(parent.width - Theme.margin * 2, 560 * Theme.scaleFactor)
                        spacing: Theme.gap / 2
                        visible: !modulePageHost.hasPage && modulePageHost.lastError.length > 0
                        CarText {
                            width: parent.width
                            text: I18n.t("模块页面加载失败")
                            color: Theme.warning
                            fontPixelSize: Theme.fontLabel
                            horizontalAlignment: Text.AlignHCenter
                        }
                        CarText {
                            width: parent.width
                            text: modulePageHost.lastError
                            color: Theme.outline
                            fontPixelSize: Theme.fontCaption
                            wrapMode: Text.WrapAnywhere
                            maximumLineCount: 6
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
            }
        }
        Flickable {
            id:calculatorFlick;objectName:"calculatorPage";clip:true;contentWidth:width;contentHeight:height;interactive:false
            boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick

            // 平板断点：>=760 走双栏（左：表达式/结果/历史，右：键盘），窄屏回单栏。
            readonly property bool calcTwoPane: width >= 760 * uiScale

            GridLayout {
                anchors.fill: parent
                columns: calculatorFlick.calcTwoPane ? 2 : 1
                columnSpacing: Theme.gap
                rowSpacing: Theme.gap

                // ---------------- 左栏：表达式 / 结果 / 历史 ----------------
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // 显示区在右：双栏时第二列；单栏时回到第一行。
                    Layout.row: 0
                    Layout.column: calculatorFlick.calcTwoPane ? 1 : 0
                    spacing: Theme.gap

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(120 * uiScale, calcResultText.implicitHeight + Theme.gap * 3)
                        color: Theme.surface
                        radius: Theme.shapeLarge
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.gap * 0.75
                            spacing: 0
                            CarText {
                                id: calcExprText
                                Layout.fillWidth: true
                                text: calcExpression.length > 0 ? calcExpression : " "
                                horizontalAlignment: Text.AlignRight
                                subdued: true
                                fontPixelSize: Theme.fontLabel
                                elide: Text.ElideLeft
                                maximumLineCount: 1
                            }
                            Text {
                                id: calcResultText
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                text: calcDisplay
                                color: Theme.foreground
                                font.pointSize: 34 * uiScale
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideLeft
                                maximumLineCount: 1
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.preferredHeight: calculatorFlick.calcTwoPane ? -1 : 150 * uiScale
                        color: Theme.surface
                        radius: Theme.shapeLarge
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.gap * 0.75
                            spacing: Theme.gap / 4
                            RowLayout {
                                Layout.fillWidth: true
                                CarText { Layout.fillWidth: true; text: I18n.t("历史"); subdued: true; fontPixelSize: Theme.fontCaption }
                                CarButton {
                                    objectName: "calcHistoryClear"
                                    text: I18n.t("清空")
                                    fontPixelSize: Theme.fontLabel
                                    enabled: calcHistory.length > 0
                                    onClicked: win.clearCalcHistory()
                                }
                            }
                            Flickable {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                contentWidth: width
                                contentHeight: historyColumn.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ColumnLayout {
                                    id: historyColumn
                                    width: parent.width
                                    spacing: Theme.gap / 4
                                    CarText {
                                        Layout.fillWidth: true
                                        visible: calcHistory.length === 0
                                        text: I18n.t("暂无记录")
                                        subdued: true
                                        fontPixelSize: Theme.fontCaption
                                    }
                                    Repeater {
                                        model: calcHistory
                                        delegate: ColumnLayout {
                                            id: historyRow
                                            required property var modelData
                                            required property int index
                                            Layout.fillWidth: true
                                            spacing: 0
                                            CarText {
                                                Layout.fillWidth: true
                                                text: modelData.expr
                                                subdued: true
                                                fontPixelSize: Theme.fontCaption
                                                elide: Text.ElideLeft
                                                maximumLineCount: 1
                                            }
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: Theme.gap / 2
                                                CarText {
                                                    Layout.fillWidth: true
                                                    text: modelData.result
                                                    fontPixelSize: Theme.fontStrong
                                                    elide: Text.ElideLeft
                                                    maximumLineCount: 1
                                                }
                                                IconButton {
                                                    objectName: "calcHistoryDelete" + historyRow.index
                                                    iconName: "close"
                                                    label: I18n.t("删除这条记录")
                                                    onClicked: win.removeCalcHistoryAt(historyRow.index)
                                                }
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: 1
                                                color: Theme.outlineVariant
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------------- 右栏：科学排 + 基础键盘 ----------------
                ColumnLayout {
                    // 计算区在左：固定宽度，剩下的给显示区。
                    Layout.fillWidth: !calculatorFlick.calcTwoPane
                    Layout.fillHeight: true
                    Layout.row: calculatorFlick.calcTwoPane ? 0 : 1
                    Layout.column: 0
                    Layout.preferredWidth: calculatorFlick.calcTwoPane ? calculatorFlick.width * 0.55 : -1
                    spacing: Theme.gap / 2

                    // 科学函数：一排 8 个，方形小圆角
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.gap / 4
                        Repeater {
                            model: ["√", "x²", "1/x", "π", "sin", "cos", "(", ")"]
                            delegate: Button {
                                id: scienceKey
                                required property string modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 40 * uiScale
                                text: modelData
                                font.pixelSize: 13 * uiScale
                                Accessible.name: I18n.t("计算器 ") + modelData
                                onClicked: calcInput(modelData)
                                background: Rectangle {
                                    radius: Theme.shapeSmall
                                    color: scienceKey.down ? Theme.pressed : Theme.surfaceContainer
                                }
                                contentItem: Text {
                                    text: scienceKey.text
                                    color: Theme.foreground
                                    font: scienceKey.font
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }

                    // 基础键盘：4×5，方形小圆角
                    GridLayout {
                        id:calculatorGrid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        columns: 4
                        rowSpacing: Theme.gap / 4
                        columnSpacing: Theme.gap / 4
                        Repeater {
                            model: ["AC", "⌫", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "-", "1", "2", "3", "+", "±", "0", ".", "="]
                            delegate: Button {
                                id: calculatorKey
                                required property string modelData
                                property bool accentKey: modelData === "="
                                property bool opKey: ["÷", "×", "-", "+"].indexOf(modelData) >= 0
                                property real keySize: Math.min((calculatorGrid.width - 3 * calculatorGrid.columnSpacing) / 4,
                                                                (calculatorGrid.height - 4 * calculatorGrid.rowSpacing) / 5)
                                text: modelData
                                Accessible.name: I18n.t("计算器 ") + modelData
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.minimumWidth: 40 * uiScale
                                Layout.minimumHeight: 40 * uiScale
                                font.pointSize: Theme.body
                                onClicked: calcInput(modelData)
                                background: Rectangle {
                                    radius: Theme.shapeMedium
                                    color: calculatorKey.accentKey
                                           ? Theme.accent
                                           : calculatorKey.down
                                             ? Theme.pressed
                                             : calculatorKey.opKey
                                               ? Theme.primaryContainer
                                               : Theme.surfaceContainerHigh
                                }
                                contentItem: Text {
                                    text: calculatorKey.text
                                    color: calculatorKey.accentKey ? Theme.accentInk : Theme.foreground
                                    font: calculatorKey.font
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }
                }
            }
        }
        Flickable {
            id:paintFlick;objectName:"paintPage";clip:true;contentWidth:width;contentHeight:Math.max(height,paintColumn.implicitHeight);interactive:contentHeight>height
            Column {id:paintColumn;width:paintFlick.width;spacing:Theme.gap/2
                RowLayout {id:paintHeader;width:paintColumn.width;spacing:Theme.gap/2
                    CarText {text:I18n.t("画图");heading:true}
                    CarText {id:paintStatus;text:I18n.t("用手指或鼠标在画布上绘制");subdued:true;Layout.fillWidth:true;elide:Text.ElideRight;maximumLineCount:1}
                    PaintToolButton {iconName:"undo";accessibleLabel:I18n.t("撤销");enabled:paintStrokes.length>0;uiScale:win.uiScale;onClicked:paintUndo()}
                    PaintToolButton {iconName:"redo";accessibleLabel:I18n.t("重做");enabled:paintRedo.length>0;uiScale:win.uiScale;onClicked:paintRedoStroke()}
                    PaintToolButton {iconName:"clear";accessibleLabel:I18n.t("清空画布");uiScale:win.uiScale;onClicked:paintClear()}
                    PaintToolButton {iconName:"save";accessibleLabel:I18n.t("保存 PNG");uiScale:win.uiScale;onClicked:{const result=systemTools.saveCameraFrame(paintCanvas.toDataURL("image/png"),systemTools.cameraPhotoPath());paintStatus.text=result===""?I18n.t("已保存到图片目录"):result}}
                }
                Item {id:paintToolsContainer;width:paintColumn.width;implicitHeight:paintTools.implicitHeight
                Flow {id:paintTools;width:parent.width;spacing:Theme.gap/2
                    Repeater {model:["#13283d","#d83d58","#e7a72f","#269c77","#3478c6","#8d55b6","#ffffff"]
                        Rectangle {required property string modelData;width:36*uiScale;height:36*uiScale;radius:width/2;color:modelData;border.width:paintColor===modelData&&!paintEraser?3:1;border.color:paintColor===modelData&&!paintEraser?Theme.accent:Theme.outline
                            TapHandler {gesturePolicy:TapHandler.DragThreshold;onTapped:{paintColor=parent.modelData;paintEraser=false}}
                        }
                    }
                    PaintToolButton {iconName:"brush";accessibleLabel:I18n.t("画笔");selected:!paintEraser&&!paintRectangle;uiScale:win.uiScale;onClicked:{paintEraser=false;paintRectangle=false}}
                    PaintToolButton {iconName:"crop_square";accessibleLabel:I18n.t("矩形");selected:paintRectangle;uiScale:win.uiScale;onClicked:{paintEraser=false;paintRectangle=true}}
                    PaintToolButton {customIcon:"qrc:/icons/eraser.svg";accessibleLabel:I18n.t("橡皮擦");selected:paintEraser;uiScale:win.uiScale;onClicked:{paintEraser=true;paintRectangle=false}}
                    Repeater {model:[2,5,10,18]
                        Button {required property int modelData;text:"●";Accessible.name:I18n.t("笔刷尺寸 ")+modelData+I18n.t(" 像素");checked:paintSize===modelData;onClicked:paintSize=modelData
                            font.pixelSize:modelData*uiScale;Layout.preferredWidth:44*uiScale;Layout.preferredHeight:44*uiScale
                            background:Rectangle{radius:Theme.shapeFull;color:parent.checked?Theme.accent:Theme.raised;border.color:parent.checked?Theme.accent:Theme.outline}
                        }
                    }
                }
                }
                Rectangle {width:paintColumn.width;height:Math.max(180*uiScale,paintFlick.height-paintHeader.height-paintToolsContainer.height-paintColumn.spacing*2);color:"white";border.color:Theme.outline;border.width:2;radius:Theme.shapeSmall
                    Canvas {id:paintCanvas;objectName:"paintCanvas";anchors.fill:parent;property var currentPoints:[];property real cursorX:0;property real cursorY:0;property bool cursorVisible:false;property int inputSamples:0
                        function redraw(){requestPaint()}
                        function clearCanvas(){paintStrokes=[];paintRedo=[];requestPaint()}
                        function sample(x,y) {
                            cursorVisible=true;cursorX=x;cursorY=y
                            const point={x:Math.max(0,Math.min(width,x)),y:Math.max(0,Math.min(height,y))}
                            inputSamples++
                            if(!currentPoints.length || Math.abs(point.x-currentPoints[currentPoints.length-1].x)+Math.abs(point.y-currentPoints[currentPoints.length-1].y)>0.25)
                                currentPoints=paintRectangle&&currentPoints.length?[currentPoints[0],point]:currentPoints.concat([point])
                            requestPaint()
                        }
                        function finishStroke() {
                            if(currentPoints.length)paintStrokes=paintStrokes.concat([{type:paintRectangle?"rectangle":"freehand",color:paintEraser?"white":paintColor,size:paintSize*uiScale,points:currentPoints}])
                            paintRedo=[];currentPoints=[];requestPaint()
                        }
                        function drawStroke(c,stroke){
                            const points=stroke.points||[];if(!points.length)return
                            c.strokeStyle=stroke.color;c.lineWidth=stroke.size;c.lineCap="round";c.lineJoin="round"
                            if(stroke.type==="rectangle"){
                                if(points.length<2)return
                                const start=points[0],end=points[points.length-1]
                                c.strokeRect(start.x,start.y,end.x-start.x,end.y-start.y);return
                            }
                            c.beginPath();c.moveTo(points[0].x,points[0].y)
                            for(let i=1;i<points.length;++i)c.lineTo(points[i].x,points[i].y)
                            if(points.length===1)c.lineTo(points[0].x+0.1,points[0].y+0.1);c.stroke()
                        }
                        onPaint:{const c=getContext("2d");c.reset();c.fillStyle="white";c.fillRect(0,0,width,height);for(let stroke of paintStrokes)drawStroke(c,stroke);if(currentPoints.length)drawStroke(c,{type:paintRectangle?"rectangle":"freehand",color:paintEraser?"white":paintColor,size:paintSize*uiScale,points:currentPoints})}
                          DragHandler {objectName:"paintInput";target:null;acceptedButtons:Qt.LeftButton
                             grabPermissions:PointerHandler.CanTakeOverFromAnything|PointerHandler.ApprovesTakeOverByAnything
                             onActiveChanged:if(active){paintCanvas.currentPoints=[];paintCanvas.sample(centroid.position.x,centroid.position.y)}else paintCanvas.finishStroke()
                             onCentroidChanged:if(active)paintCanvas.sample(centroid.position.x,centroid.position.y)
                         }
                    }
                    Rectangle {id:paintPreview;enabled:false;visible:paintCanvas.cursorVisible;width:Math.max(8,paintSize*uiScale);height:width;x:paintCanvas.x+paintCanvas.cursorX-width/2;y:paintCanvas.y+paintCanvas.cursorY-height/2;radius:width/2;color:paintEraser?"transparent":paintColor;opacity:paintEraser?1:0.45;border.width:Math.max(1,uiScale);border.color:paintEraser?"#111111":paintColor}
                }
            }
        }
        Flickable {
            id:notesFlick;objectName:"notesPage";clip:true;contentWidth:width;contentHeight:height;interactive:false
            boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
            ColumnLayout {id:notesColumn;width:notesFlick.width;height:notesFlick.height;spacing:4
                CarText {text:I18n.t("保存位置：")+systemTools.filesRoot+"/"+noteFile;subdued:true;Layout.fillWidth:true;elide:Text.ElideMiddle}
                EditorToolbar {Layout.fillWidth:true;editor:noteEditor;formatter:documentFormatter;rich:true;allowRichSave:true;onSaveRequested:saveNote();onSaveRichRequested:noteSaveAsDialog.open()}
                ScrollView {id:notesScroll;Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:80;clip:true
                    TextArea {id:noteEditor;text:documentFormatter.richText(noteText,false);textFormat:TextEdit.RichText;selectByMouse:true;persistentSelection:true;wrapMode:Text.Wrap;font.pointSize:Theme.body;color:"#1f1f1f";selectionColor:Theme.accent;selectedTextColor:Theme.accentInk;padding:16;topPadding:16;bottomPadding:16;topInset:0;bottomInset:0
                        background:Rectangle {color:"#fffdf8";radius:Theme.shapeSmall}
                    }
                }
                RowLayout {Layout.fillWidth:true
                    CarText {id:notesStatus;text:I18n.t("纯文本不保留格式，请另存 HTML");subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                    CarText {text:I18n.t("字符数")+": "+noteEditor.getText(0,noteEditor.length).length;subdued:true}
                }
            }
        }
        MusicPlayer {id:musicPage;objectName:"musicPlayerPage";active:win.section===9 && win.phase!=="home";uiScale:win.uiScale
            onMediaPlayingChanged:if(mediaPlaying){devicePanel.preferVideo=false;videoPage.pauseMedia();tvPage.pauseMedia()}}
        VideoPlayer {id:videoPage;objectName:"videoPlayerPage";active:win.section===10 && win.phase!=="home";uiScale:win.uiScale;hostWindow:win;onFullscreenChanged:win.videoFullscreen=fullscreen
            onMediaPlayingChanged:if(mediaPlaying){devicePanel.preferVideo=true;musicPage.pauseMedia();tvPage.pauseMedia()}}
        TvPlayer {id:tvPage;objectName:"tvPlayerPage";active:win.section===11 && win.phase!=="home";uiScale:win.uiScale;hostWindow:win;virtualKeyboard:screenKeyboard;onKeyboardRequested:screenKeyboard.show()
            onMediaPlayingChanged:if(mediaPlaying){devicePanel.preferVideo=true;musicPage.pauseMedia();videoPage.pauseMedia()}}
        TimeTools {id:timePage;objectName:"timeToolsPage";active:win.section===12 && win.phase!=="home";uiScale:win.uiScale;alarmEngine:win.alarmBackend;timeSync:win.timeSyncBackend;clockFace:win.clockFace;timeFormat:win.timeFormat
            onNotifyRequested:function(title,message,important){win.notify(title,message,important,I18n.t("时间"),"schedule")}
            onAnnounceRequested:function(text){win.announce(text)}
            onKeyboardRequested:if(!screenKeyboard.visible)screenKeyboard.show()}
        VoiceSettings {id:voicePage;objectName:"voiceSettingsPage";active:win.section===13 && win.phase!=="home";uiScale:win.uiScale;hostWindow:win}
        // 播报输出设备：跟随系统（默认）或固定到某个 Qt Multimedia 输出设备。
        Popup {
            id:audioOutputPopup
            objectName:"audioOutputPopup"
            parent:Overlay.overlay
            anchors.centerIn:Overlay.overlay
            modal:true;dim:true;closePolicy:Popup.CloseOnEscape
            padding:Theme.gap
            width:Math.min(560*Theme.scaleFactor,(parent?parent.width:800)-Theme.gap*4)
            background:Rectangle{radius:Theme.shapeLarge;color:Theme.surface;border.color:Theme.outline;border.width:1}
            contentItem: Loader {
                active: audioOutputPopup.opened
                sourceComponent: Component {
                ColumnLayout {
                spacing:Theme.gap/2
                CarText {Layout.fillWidth:true;text:I18n.t("播报输出设备");heading:true}
                CarText {Layout.fillWidth:true;wrapMode:Text.Wrap;subdued:true;fontPixelSize:Theme.fontCaption
                    text:I18n.t("仅影响语音播报；音乐、视频与铃声仍跟随系统输出。")}
                CarButton {objectName:"audioOutputFollowSystem";Layout.fillWidth:true
                    text:I18n.t("跟随系统")+(systemTools.audioOutputDevice===""?"  ✓":"")
                    onClicked:{systemTools.setAudioOutputDevice("");audioOutputPopup.close()}
                }
                Flickable {
                    Layout.fillWidth:true
                    Layout.preferredHeight:Math.min(outputColumn.implicitHeight,280*Theme.scaleFactor)
                    contentHeight:outputColumn.implicitHeight
                    clip:true
                    boundsBehavior:Flickable.StopAtBounds
                    ColumnLayout {id:outputColumn;width:parent.width;spacing:0
                        Repeater {
                            model:systemTools.audioOutputs
                            delegate:OutputDeviceRow{rowData:modelData}
                        }
                    }
                }
                RowLayout {Layout.fillWidth:true;spacing:Theme.gap/2
                    Item{Layout.fillWidth:true}
                    CarButton {text:I18n.t("关闭");onClicked:audioOutputPopup.close()}
                }
                }
                }
            }
        }
        component OutputDeviceRow: CarButton {
            property var rowData: null
            Layout.fillWidth:true
            text:(rowData?rowData.name:"")+(rowData&&rowData.selected?"  ✓":"")
            onClicked:{if(rowData){systemTools.setAudioOutputDevice(rowData.id);audioOutputPopup.close()}}
        }
        // 「测试音色」彩蛋确认：开启后 BanG Dream 分类才会出现在音色页。
        Popup {
            id:voiceTestConfirm
            objectName:"voiceTestConfirm"
            parent:Overlay.overlay
            anchors.centerIn:Overlay.overlay
            modal:true;dim:true;closePolicy:Popup.CloseOnEscape
            padding:Theme.gap
            width:Math.min(520*Theme.scaleFactor,(parent?parent.width:800)-Theme.gap*4)
            background:Rectangle{radius:Theme.shapeLarge;color:Theme.surface;border.color:Theme.outline;border.width:1}
            contentItem: Loader {
                active: voiceTestConfirm.opened
                sourceComponent: Component {
                ColumnLayout {
                spacing:Theme.gap/2
                CarText {
                    Layout.fillWidth:true;wrapMode:Text.Wrap
                    text:I18n.t("即将开启语音播报测试模式，此类声音为测试版效果较差，可能降低使用体验")
                }
                CarText {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;subdued:true;fontPixelSize:Theme.fontCaption
                    text:I18n.t("可在音色页随时关闭；关闭后自动切回晓晓。")
                }
                RowLayout {
                    Layout.fillWidth:true;spacing:Theme.gap/2
                    Item{Layout.fillWidth:true}
                    CarButton {objectName:"voiceTestCancel";text:I18n.t("取消");onClicked:voiceTestConfirm.close()}
                    CarButton {objectName:"voiceTestConfirmButton";text:I18n.t("确认开启");accent:true
                        onClicked:{systemTools.setVoiceTestMode(true);voiceTestConfirm.close();if(win.section!==13)win.openVoicePage()}
                    }
                }
                }
                }
            }
        }
        WeatherTools {id:weatherPage;objectName:"weatherToolsPage";active:win.section===14 && win.phase!=="home";uiScale:win.uiScale;weatherEngine:weatherEngine
            onKeyboardRequested:if(!screenKeyboard.visible)screenKeyboard.show()
            onAnnounceRequested:function(text){win.announce(text)}}
        UserSecurityView {id:userSecurityView;objectName:"userSecurityView";active:win.section===15 && win.phase!=="home";uiScale:win.uiScale
            onKeyboardRequested:if(!screenKeyboard.visible)screenKeyboard.show()
            onKeyboardDismissed:screenKeyboard.hide()}
            }
            // 「关于本机」二级页：覆盖内容区（不盖窗口标题栏），从右侧滑入。
            // 用显式矩形而不是 anchors.fill，否则 x 会被 anchors 锁死，滑入动画无法生效。
            AboutDevicePage {
                id:aboutDevicePage
                objectName:"aboutDevicePage"
                width:pages.width
                height:pages.height
                y:pages.y
                open:win.aboutDeviceOpen
                onCloseRequested:win.aboutDeviceOpen=false
                onKeyboardRequested:screenKeyboard.show()
                onKeyboardDismissRequested:screenKeyboard.hide()
            }
            // 「各功能联网权限」二级页：与关于本机同一层、同一套滑入动画。
            // 权限页很重（Repeater + SettingsGroup）；只在首次打开时创建，
            // 之后保持实例（created），让打开和返回都有 240ms 滑入/滑出动画。
            // 每次打开即销毁会让 open 初始为 true、x 直接为 0，动画整体失效。
            Loader {
                id:networkPermissionsPageLoader
                objectName:"networkPermissionsPageHost"
                width:pages.width
                height:pages.height
                y:pages.y
                property bool created:false
                active:win.networkPermissionsOpen || created
                onLoaded:{
                    created=true
                    // 二级页只发 keyboardRequested；键盘对象归 Main 管，
                    // 这样键盘和页面位移共用同一套状态。
                    if (item && item.keyboardRequested)
                        item.keyboardRequested.connect(screenKeyboard.show)
                }
                sourceComponent:Component {
                    NetworkPermissionsPage {
                        width:networkPermissionsPageLoader.width
                        height:networkPermissionsPageLoader.height
                        open:win.networkPermissionsOpen
                        onCloseRequested:win.networkPermissionsOpen=false
                    }
                }
            }
            Popup {
                id:browserHttpConfirm
                objectName:"browserHttpConfirm"
                parent:Overlay.overlay
                anchors.centerIn:Overlay.overlay
                modal:true
                dim:true
                closePolicy:Popup.CloseOnEscape
                padding:Theme.gap
                width:Math.min(520*uiScale,(parent?parent.width:800)-Theme.gap*4)
                background:Rectangle {radius:Theme.shapeLarge;color:Theme.surface;border.color:Theme.outline;border.width:1}
                contentItem: Loader {
                    active: browserHttpConfirm.opened
                    sourceComponent: Component {
                    ColumnLayout {
                    spacing:Theme.gap/2
                    CarText {Layout.fillWidth:true;heading:true;text:I18n.t("打开不安全的 HTTP 网页？")}
                    CarText {Layout.fillWidth:true;wrapMode:Text.Wrap
                        text:I18n.t("该地址不是 HTTPS。页面内容、Cookie 和表单可能被同一网络中的攻击者读取或篡改。")}
                    CarText {Layout.fillWidth:true;wrapMode:Text.Wrap;subdued:true;fontPixelSize:Theme.fontCaption;text:win.browserHttpPending}
                    RowLayout {
                        Layout.fillWidth:true;spacing:Theme.gap/2
                        Item {Layout.fillWidth:true}
                        CarButton {objectName:"browserHttpCancel";text:I18n.t("取消");onClicked:browserHttpConfirm.close()}
                        CarButton {objectName:"browserHttpAccept";text:I18n.t("仍然打开");accent:true
                            onClicked:{const target=win.browserHttpPending;browserHttpConfirm.close();if(target!=="")win.loadBrowserAddress(target)}}
                    }
                    }
                    }
                }
            }
        }
    }
    WebEngineProfile {
        id:terminalViperProfile;objectName:"terminalViperProfile"
        storageName:"ViperTerminal"
        persistentStoragePath:viperBrowser.profileStoragePath()
        cachePath:viperBrowser.profileCachePath()
        httpCacheType:WebEngineProfile.DiskHttpCache
        persistentCookiesPolicy:WebEngineProfile.AllowPersistentCookies
        Component.onCompleted: {
            if(!viperBrowser.attachProfile(terminalViperProfile))console.error("Viper failed to attach its request policies to the Quick WebEngine profile")
        }
    }
    WebEngineProfile {
        id:terminalPrivateProfile;objectName:"terminalPrivateProfile"
        offTheRecord:true
        Component.onCompleted: if(!viperBrowser.attachPrivateProfile(terminalPrivateProfile))console.error("Viper failed to attach private profile policies")
    }
    Drawer {
        id:devicePanel;objectName:"deviceControlPanel";parent:Overlay.overlay;edge:Qt.BottomEdge;x:0;width:parent.width;height:Math.min(820*uiScale,parent.height)
        padding:Theme.shapeExtraLarge;modal:true;dragMargin:0
        property bool jumpToNotifications:false
        property bool preferVideo:false
        property bool volumeExpanded:false
        readonly property bool mediaVideo:videoPage.hasMedia&&(preferVideo||!musicPage.hasMedia)
        readonly property var media:mediaVideo?videoPage:musicPage
        background:GlassSurface {objectName:"quickPanelBlur";blurCacheTexture:win.panelBlurTexture;color:Theme.surface;radius:0;blurStrength:3.2;tintOpacity:0.46;blurEnabled:!repairRawQuickBlur;staticBlur:true}
        Overlay.modal:Rectangle {color:"#99040b14"}
        property bool blurCapturePending:false
        property bool blurPrepared:false
        property real firstBlurCapturePosition:-1
        function captureBlur(item,offset) {
            if(!item)return
            if(typeof item.captureStaticBlur==="function")item.captureStaticBlur(offset)
            const childItems=item.children
            if(childItems)for(let i=0;i<childItems.length;++i)captureBlur(childItems[i],offset)
        }
        function refreshStaticBlur() {
            if(blurCapturePending)return
            blurCapturePending=true
            Qt.callLater(function(){
                devicePanel.blurCapturePending=false
                if(!devicePanel.visible)return
                const source=devicePanel.background.backdrop
                if(!source)return
                // Sample the final panel coordinates before the slide finishes.
                // The frozen texture then travels with the panel; no live sampling.
                const current=devicePanel.background.mapToItem(source,0,0)
                const target=devicePanel.parent.mapToItem(source,devicePanel.x,devicePanel.parent.height-devicePanel.height)
                const offset=Qt.point(target.x-current.x,target.y-current.y)
                devicePanel.captureBlur(devicePanel.background,offset)
                devicePanel.captureBlur(devicePanel.contentItem,offset)
                if(!devicePanel.blurPrepared)devicePanel.firstBlurCapturePosition=devicePanel.position
                devicePanel.blurPrepared=true
            })
        }
        onAboutToShow:{blurPrepared=false;firstBlurCapturePosition=-1;refreshStaticBlur();systemTools.systemVolume.refresh()}
        onClosed:volumeExpanded=false
        Timer {interval:5000;repeat:true;running:devicePanel.visible;onTriggered:systemTools.systemVolume.refresh()}
        onVisibleChanged:if(visible)refreshStaticBlur()
        onOpened:{win.markNotificationsRead();if(!blurPrepared)refreshStaticBlur()}
        onWidthChanged:refreshStaticBlur()
        onHeightChanged:refreshStaticBlur()
        Connections {target:devicePanel.media;function onHasMediaChanged(){devicePanel.refreshStaticBlur()}}
        Connections {target:systemTools;function onEnergySavingChanged(){devicePanel.refreshStaticBlur()}}
        Connections {target:notices;function onCountChanged(){devicePanel.refreshStaticBlur()}}
        contentItem:Flickable {
            id:controlFlick;clip:true;contentWidth:width;contentHeight:Math.max(height,controlColumn.implicitHeight);boundsBehavior:Flickable.StopAtBounds
            ColumnLayout {
                id:controlColumn;width:controlFlick.width;spacing:Theme.gap
                RowLayout {id:quickHeader;Layout.fillWidth:true;spacing:Theme.gap
                    ColumnLayout {Layout.fillWidth:true;spacing:0
                        CarText {text:win.clockText;hero:true;Layout.fillWidth:true}
                         CarText {objectName:"quickPanelDate";text:win.localizedLongDate;subdued:true;Layout.fillWidth:true}
                    }
                    IconButton {iconName:"close";label:I18n.t("关闭设备面板");onClicked:devicePanel.close()}
                }
                RowLayout {
                    id:quickMediaRow;Layout.fillWidth:true;spacing:Theme.gap
                    Rectangle {
                        objectName:"quickMediaCard"
                        visible:devicePanel.media.hasMedia
                        Layout.fillWidth:true;Layout.preferredWidth:controlFlick.width*0.48;Layout.minimumWidth:0;implicitHeight:mediaContents.implicitHeight+24*uiScale
                        radius:Theme.shapeLarge;color:"transparent"
                        GlassSurface {objectName:"quickMediaBlur";blurCacheTexture:win.panelBlurTexture;anchors.fill:parent;color:Theme.raised;radius:Theme.shapeLarge;blurEnabled:!repairRawQuickBlur;staticBlur:true;blurStrength:3.2;tintOpacity:0.40}
                        ColumnLayout {id:mediaContents;x:12*uiScale;y:12*uiScale;width:Math.max(0,parent.width-24*uiScale);spacing:4
                            RowLayout {Layout.fillWidth:true
                                MaterialIcon {name:devicePanel.mediaVideo?"image":"volume_up";Layout.preferredWidth:24;Layout.preferredHeight:24}
                                CarText {text:devicePanel.mediaVideo?videoPage.selectedFile:musicPage.currentTitle;heading:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                IconButton {iconName:"chevron_right";label:I18n.t("打开播放器");onClicked:{devicePanel.close();win.auditPage(devicePanel.mediaVideo?10:9)}}
                            }
                            CarText {text:(devicePanel.media.mediaPlaying?I18n.t("正在播放"):I18n.t("已暂停"))+(devicePanel.mediaVideo?"":"，"+musicPage.currentArtist);subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                            RowLayout {Layout.alignment:Qt.AlignHCenter
                                IconButton {iconName:"skip_previous";label:devicePanel.mediaVideo?I18n.t("上一个视频"):I18n.t("上一首");onClicked:devicePanel.mediaVideo?videoPage.navigateMedia(-1):musicPage.navigatePlayback(-1,false)}
                                IconButton {iconName:devicePanel.media.mediaPlaying?"pause":"play_arrow";filled:true;label:I18n.t("播放/暂停");onClicked:devicePanel.media.toggleMedia()}
                                IconButton {iconName:"skip_next";label:devicePanel.mediaVideo?I18n.t("下一个视频"):I18n.t("下一首");onClicked:devicePanel.mediaVideo?videoPage.navigateMedia(1):musicPage.navigatePlayback(1,false)}
                            }
                            ProgressBar {Layout.fillWidth:true;from:0;to:Math.max(1,devicePanel.media.mediaDuration);value:devicePanel.media.mediaPosition;Accessible.name:I18n.t("播放进度")}
                        }
                    }
                    GridLayout {Layout.preferredWidth:quickControlsFlick.width;Layout.minimumWidth:quickControlsFlick.width;Layout.maximumWidth:quickControlsFlick.width;Layout.alignment:Qt.AlignVCenter;columns:2;columnSpacing:quickStatusGrid.columnSpacing;rowSpacing:quickStatusGrid.rowSpacing
                        QuickPanelTile {blurCacheTexture:win.panelBlurTexture;objectName:"quickHotspotTile";blurObjectName:"quickHotspotBlur";blurEnabled:!repairRawQuickBlur;Layout.fillWidth:true;label:I18n.t("Wi-Fi 热点");iconName:systemTools.deviceStatus.hotspotActive?"wifi":"wifi_off";active:!!systemTools.deviceStatus.hotspotActive;detail:systemTools.hotspotBusy?I18n.t("正在切换…"):!systemTools.deviceStatus.hotspotKnown?I18n.t("状态未知"):active?I18n.t("已开启，模块可连接"):I18n.t("未开启，点击启用");enabled:!systemTools.hotspotBusy&&!!systemTools.deviceStatus.hotspotKnown;onClicked:systemTools.hotspot(!active)}
                        QuickPanelTile {blurCacheTexture:win.panelBlurTexture;objectName:"quickBluetoothTile";blurObjectName:"quickBluetoothBlur";blurEnabled:!repairRawQuickBlur;Layout.fillWidth:true;label:"Bluetooth";iconName:"bluetooth";active:!!systemTools.deviceStatus.bluetoothOn;detail:!systemTools.deviceStatus.bluetoothAvailable?I18n.t("没有适配器"):active?I18n.t("已开启"):I18n.t("已关闭");enabled:!!systemTools.deviceStatus.bluetoothAvailable;onClicked:systemTools.setBluetoothEnabled(!active)}
                        QuickPanelTile {blurCacheTexture:win.panelBlurTexture;objectName:"quickSystemTile";blurObjectName:"quickSystemBlur";blurEnabled:!repairRawQuickBlur;Layout.fillWidth:true;label:I18n.t("系统");detail:I18n.t("重启 / 关机");iconName:"power"
                            // 访客只灰显，不加锁角标；点击弹无权限（锁屏电源键不在此列）。
                            opacity:sessionManager.guestSession?0.4:1
                            onClicked:{ devicePanel.close()
                                if (sessionManager.guestSession) restrictedNotice.show(I18n.t("系统"))
                                else systemActionsDialog.open() }}
                        QuickPanelTile {blurCacheTexture:win.panelBlurTexture;objectName:"quickVolumeTile";blurObjectName:"quickVolumeBlur";blurEnabled:!repairRawQuickBlur;Layout.fillWidth:true;label:I18n.t("音量");iconName:systemTools.systemVolume.muted||systemTools.systemVolume.volume===0?"volume_off":"volume_up";active:devicePanel.volumeExpanded
                            detail:!systemTools.systemVolume.available?I18n.t("音频输出不可用"):systemTools.systemVolume.muted?I18n.t("已静音"):systemTools.systemVolume.volume+"%"
                            onClicked:{devicePanel.volumeExpanded=!devicePanel.volumeExpanded;systemTools.systemVolume.refresh()}
                        }
                         Rectangle {objectName:"quickVolumeControls";visible:devicePanel.visible&&devicePanel.volumeExpanded;Layout.columnSpan:2;Layout.fillWidth:true;implicitHeight:volumeContents.implicitHeight+32*uiScale;radius:Theme.shapeLarge;color:Theme.surface
                             Column {id:volumeContents;x:16*uiScale;y:16*uiScale;width:Math.max(0,parent.width-32*uiScale);spacing:8*uiScale
                                RowLayout {width:volumeContents.width
                                    CarText {text:I18n.t("系统音量");heading:true;Layout.fillWidth:true}
                                    CarText {text:systemTools.systemVolume.available?Math.round(systemVolumeSlider.value)+"%":"—";subdued:true}
                                    IconButton {iconName:"close";label:I18n.t("收起音量调节");implicitWidth:Math.max(48,Theme.hit);implicitHeight:Math.max(48,Theme.hit);onClicked:devicePanel.volumeExpanded=false}
                                }
                                RowLayout {width:volumeContents.width;spacing:16*uiScale
                                    IconButton {objectName:"systemMuteButton";iconName:systemTools.systemVolume.muted?"volume_off":"volume_up";label:systemTools.systemVolume.muted?I18n.t("取消静音"):I18n.t("静音");implicitWidth:Math.max(48,Theme.hit);implicitHeight:Math.max(48,Theme.hit);enabled:systemTools.systemVolume.available;onClicked:systemTools.systemVolume.setMuted(!systemTools.systemVolume.muted)}
                                    Slider {id:systemVolumeSlider;objectName:"systemVolumeSlider";Layout.fillWidth:true;implicitHeight:Math.max(48,48*uiScale,Theme.hit);from:0;to:100;stepSize:1;enabled:systemTools.systemVolume.available;Accessible.name:I18n.t("系统音量")
                                        Binding {target:systemVolumeSlider;property:"value";value:systemTools.systemVolume.volume;when:!systemVolumeSlider.pressed}
                                        onMoved:systemTools.systemVolume.setVolume(Math.round(value))
                                    }
                                }
                                CarText {visible:!systemTools.systemVolume.available;text:I18n.t("无法连接系统音频服务，请检查音频输出。");subdued:true;width:volumeContents.width;wrapMode:Text.Wrap}
                            }
                        }
                    }
                }
                Item {
                    id:quickSplit;Layout.fillWidth:true;Layout.minimumWidth:0;Layout.preferredHeight:Math.max(180*uiScale,controlFlick.height-quickHeader.height-quickMediaRow.height-Theme.gap*2)
                    Flickable {
                        id:quickControlsFlick;objectName:"quickControlsPane"
                        onMovementEnded:devicePanel.refreshStaticBlur()
                        x:0;y:0;height:parent.height;width:parent.width*(parent.width>760*uiScale?0.52:0.48)
                        clip:true
                        contentWidth:width;contentHeight:quickControlsColumn.implicitHeight
                        boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
                        ColumnLayout {id:quickControlsColumn;width:quickControlsFlick.width;spacing:Theme.gap/2
                CarText {text:I18n.t("屏幕亮度由显示器调节");subdued:true;Layout.fillWidth:true}
                GridLayout {
                    id:quickStatusGrid;Layout.fillWidth:true;columns:2;columnSpacing:Theme.gap/2;rowSpacing:Theme.gap/2
                    Repeater {model:[
                        {icon:"power",title:I18n.t("电源"),value:systemTools.deviceStatus.batteryPresent?systemTools.deviceStatus.batteryPercent+"%，"+(systemTools.deviceStatus.batteryState||I18n.t("电池")):I18n.t("未检测到电池")},
                        {icon:"extension",title:I18n.t("模块"),value:connectionManager.cards.length+I18n.t(" 个会话")},
                        {icon:"lan",title:I18n.t("控制桥"),value:!connectionManager.bridgeMonitoring?I18n.t("未配置"):connectionManager.bridgeConnected?I18n.t("USB已连接"):I18n.t("USB未连接")},
                        {icon:"memory",title:I18n.t("内存"),value:systemTools.deviceStatus.memoryLabel||I18n.t("读取中")},
                        {icon:"storage",title:I18n.t("存储"),value:systemTools.deviceStatus.storageLabel||I18n.t("读取中")}
                    ]
                        delegate:Rectangle {
                            required property var modelData
                            Layout.fillWidth:true;Layout.preferredHeight:88*uiScale;color:"transparent"
                            GlassSurface {blurCacheTexture:win.panelBlurTexture;anchors.fill:parent;color:Theme.background;radius:Theme.shapeLarge;blurEnabled:!repairRawQuickBlur;staticBlur:true;blurStrength:3.2;tintOpacity:0.30}
                            RowLayout {anchors.fill:parent;anchors.margins:Theme.gap/1.5;spacing:Theme.gap/2
                                MaterialIcon {name:modelData.icon;Layout.preferredWidth:24*uiScale;Layout.preferredHeight:24*uiScale}
                                ColumnLayout {Layout.fillWidth:true;spacing:0
                                    CarText {text:modelData.title;subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                    CarText {text:modelData.value;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                }
                            }
                        }
                    }
                }
                        }
                    }
                    Flickable {
                        id:notificationsPane;objectName:"quickNotificationsPane"
                        onMovementEnded:devicePanel.refreshStaticBlur()
                        x:quickControlsFlick.width+Theme.gap;y:0;height:parent.height;width:Math.max(0,parent.width-x);clip:true
                        contentWidth:width;contentHeight:notificationColumn.implicitHeight
                        boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
                        ColumnLayout {id:notificationColumn;width:notificationsPane.width;spacing:Theme.gap/2
                RowLayout {Layout.fillWidth:true
                    CarText {id:notificationsTitle;text:I18n.t("通知");heading:true;Layout.fillWidth:true}
                    IconButton {visible:notices.count>0;iconName:"clear";label:I18n.t("清除通知");enabled:notices.count>0;onClicked:{notices.clear();win.recountNotifications()}}
                }
                CarText {visible:notices.count===0;text:I18n.t("暂无通知");subdued:true;Layout.fillWidth:true}
                Repeater {model:notices
                    Rectangle {
                        required property int index
                        required property string message
                         required property string title
                         required property string time
                        required property string appName
                        required property string iconName
                        required property bool important
                        Layout.fillWidth:true;implicitHeight:noticeColumn.implicitHeight+Theme.gap*2
                        color:"transparent";radius:Theme.shapeLarge
                        GlassSurface {blurCacheTexture:win.panelBlurTexture;objectName:"quickNotificationBlur";anchors.fill:parent;color:Theme.background;radius:Theme.shapeLarge;borderColor:important?"#ffc66d":Theme.outline;borderWidth:1;blurEnabled:!repairRawQuickBlur;staticBlur:true;blurStrength:3.2;tintOpacity:0.40}
                        ColumnLayout {id:noticeColumn;x:Theme.gap;y:Theme.gap;width:parent.width-Theme.gap*2
                            RowLayout {Layout.fillWidth:true
                                MaterialIcon {name:iconName;Layout.preferredWidth:28*uiScale;Layout.preferredHeight:28*uiScale}
                                CarText {text:appName+"，"+time;font.pointSize:Theme.body*0.95;font.weight:Font.DemiBold;subdued:true;Layout.fillWidth:true;elide:Text.ElideRight;maximumLineCount:1}
                                IconButton {iconName:"close";label:I18n.t("移除通知");onClicked:{notices.remove(index);win.recountNotifications()}}
                            }
                            CarText {visible:title!=="";text:title;font.pointSize:Theme.body*1.05;font.weight:Font.DemiBold;Layout.fillWidth:true;wrapMode:Text.Wrap}
                            CarText {text:message;Layout.fillWidth:true;wrapMode:Text.Wrap}
                        }
                    }
                }
            }
                    }
                }
                }
            }
        }
    ApplicationDrawer {
        id: appDrawer
        model: homeCards
        uiScale: win.uiScale
        hostWidth: win.width
        hostHeight: win.height
        onEntryActivated: function(entry, originX, originY) { win.launch(entry, originX, originY) }
    }
    Connections {
        target:terminalViperProfile
        function onDownloadRequested(download) { win.enqueueBrowserDownload(download) }
    }
    Connections {
        target:terminalPrivateProfile
        function onDownloadRequested(download) { win.enqueueBrowserDownload(download) }
    }
    Repeater {
        id:browserDownloadMonitors;objectName:"browserDownloadMonitors"
        model:browserDownloads
        delegate:Item {
            required property var modelData
            visible:false;width:0;height:0
            Connections {
                target:modelData.request
                function onReceivedBytesChanged() {
                    if(target)win.updateBrowserDownload(target,{received:target.receivedBytes,total:target.totalBytes})
                }
                function onIsPausedChanged() {
                    if(target)win.updateBrowserDownload(target,{status:target.isPaused?I18n.t("已暂停"):I18n.t("正在下载")})
                }
                function onIsFinishedChanged() {
                    if(target&&target.isFinished)win.finishBrowserDownload(target)
                }
            }
        }
    }
    Connections {
        target:viperBrowser
        function onBookmarksChanged() { browserBookmarks=viperBrowser.bookmarks() }
        function onHistoryChanged() { browserHistory=viperBrowser.recentHistory() }
        function onAdBlockDataReady(token,css,script) {
            const view=browserRepeater.itemAt(token)
            if(!view || view.url.toString()!==view.filterInjectedUrl)return
            if(css)view.runJavaScript(css)
            if(script)view.runJavaScript(script)
        }
    }
    Dialog {
        id:wallpaperPicker;objectName:"wallpaperPicker";parent:Overlay.overlay;modal:true
        title:I18n.t("选择桌面壁纸");width:Math.min(700*uiScale,win.width-32);height:Math.min(560*uiScale,win.height-32)
        x:(win.width-width)/2;y:(win.height-height)/2
        onOpened:wallpaperFolder=""
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeLarge}
        contentItem:ColumnLayout {
            CarText {text:systemTools.filesRoot+(wallpaperFolder?"/"+wallpaperFolder:"");Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle;subdued:true}
            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                CarButton {text:I18n.t("主目录");onClicked:wallpaperFolder=""}
                CarButton {text:I18n.t("上一级");enabled:wallpaperFolder!=="";onClicked:wallpaperFolder=wallpaperFolder.substring(0,Math.max(0,wallpaperFolder.lastIndexOf("/")))}
            }
            ListView {
                objectName:"wallpaperFileList";Layout.fillWidth:true;Layout.fillHeight:true;clip:true
                model:systemTools.files(wallpaperFolder).sort(function(a,b){if(a.directory!==b.directory)return a.directory?-1:1;return a.name.localeCompare(b.name)})
                delegate:ItemDelegate {
                    required property var modelData;width:ListView.view.width
                    visible:modelData.directory||/\.(png|jpe?g|webp|bmp|gif)$/i.test(modelData.name);height:visible?Theme.hit:0
                    contentItem:RowLayout {spacing:Theme.gap
                        MaterialIcon {name:modelData.directory?"folder":"image";Layout.preferredWidth:28*uiScale;Layout.preferredHeight:28*uiScale}
                        Text {text:modelData.name;color:Theme.foreground;font:parent.parent.font;Layout.fillWidth:true;elide:Text.ElideMiddle}
                    }
                    onClicked:activateWallpaperEntry(modelData)
                }
            }
            Flow {Layout.fillWidth:true;spacing:Theme.gap/2
                CarButton {text:I18n.t("取消");onClicked:wallpaperPicker.close()}
            }
        }
    }
    Dialog {
        id:opacityDialog;objectName:"opacityDialog";parent:Overlay.overlay;modal:true;opacity:1
        x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(640*uiScale,win.width-Theme.gap*2);height:Math.min(560*uiScale,win.height-Theme.gap*2)
        padding:Theme.shapeExtraLarge;title:I18n.t("界面不透明度")
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeLarge}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:opacityContents.implicitHeight
            ColumnLayout {id:opacityContents;width:parent.width;spacing:Theme.gap
                CarText {text:I18n.t("主页卡片：")+Math.round(systemTools.launcherOpacity*100)+"%";Layout.fillWidth:true}
                Slider {objectName:"launcherOpacitySlider";Layout.fillWidth:true;implicitHeight:Theme.hit;from:0;to:1;stepSize:0.01;value:systemTools.launcherOpacity;Accessible.name:I18n.t("主页卡片不透明度");onMoved:systemTools.setLauncherOpacity(value)}
                CarText {text:I18n.t("模块界面：")+Math.round(systemTools.moduleOpacity*100)+"%";Layout.fillWidth:true}
                Slider {objectName:"moduleOpacitySlider";Layout.fillWidth:true;implicitHeight:Theme.hit;from:0;to:1;stepSize:0.01;value:systemTools.moduleOpacity;Accessible.name:I18n.t("模块界面不透明度");onMoved:systemTools.setModuleOpacity(value)}
                Flow {Layout.fillWidth:true;spacing:Theme.gap
                    CarButton {text:I18n.t("恢复 65%");onClicked:{systemTools.setLauncherOpacity(0.65);systemTools.setModuleOpacity(0.65)}}
                    CarButton {text:I18n.t("完成");onClicked:opacityDialog.close()}
                }
            }
        }
    }
    Dialog {
        id:trustDialog; modal:true; closePolicy:Popup.NoAutoClose
        x:(win.width-width)/2; y:(win.height-height)/2
        width:Math.min(760*uiScale,win.width-Theme.gap*2)
        height:Math.min(trustContents.implicitHeight+Theme.gap*2,win.height-Theme.gap*2)
        padding:Theme.shapeExtraLarge; background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.accent;borderWidth:2}
        onClosed:Qt.callLater(showNextTrust)
        contentItem:Flickable {
            clip:true; contentWidth:width; contentHeight:trustContents.implicitHeight
            boundsBehavior:Flickable.StopAtBounds; flickableDirection:Flickable.VerticalFlick
            ColumnLayout {
                id:trustContents; width:parent.width; spacing:Theme.gap
                CarText {text:I18n.t("确认模块权限");heading:true;Layout.fillWidth:true}
                CarText {text:trustItem.title;heading:true;Layout.fillWidth:true}
                CarText {text:I18n.t("签名已验证。声明权限：")+trustItem.permissions.join("、");Layout.fillWidth:true}
                CarText {text:I18n.t("插件在本程序内运行，请只允许可信发布者的功能。");subdued:true;Layout.fillWidth:true}
                CarText {text:I18n.t("信任签名不授予网络或文件权限；如需使用，请在“设置 → 联网权限”经管理员 PIN 单独开启。");subdued:true;Layout.fillWidth:true}
                Flow {Layout.fillWidth:true;spacing:Theme.gap
                    IconButton {iconName:"check";label:I18n.t("仅本次信任");filled:true;onClicked:approveTrustOnce()}
                    IconButton {iconName:"check";label:I18n.t("始终信任此发布者");onClicked:{connectionManager.trust(trustItem.instance,true);trustDialog.close()}}
                    IconButton {iconName:"close";label:I18n.t("拒绝并断开");onClicked:{connectionManager.disconnectModule(trustItem.instance);trustDialog.close()}}
                }
            }
        }
    }
    Dialog {
        id:systemActionsDialog;objectName:"systemActionsDialog";parent:Overlay.overlay;z:1000;modal:true
        x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(600*uiScale,win.width-Theme.gap*2);height:Math.min(systemActionsColumn.implicitHeight+topPadding+bottomPadding,win.height-Theme.gap*2)
        padding:Theme.shapeExtraLarge;background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:systemActionsColumn.implicitHeight;boundsBehavior:Flickable.StopAtBounds
        ColumnLayout {
            id:systemActionsColumn;width:parent.width;spacing:Theme.gap
            CarText {text:I18n.t("系统控制");heading:true;Layout.fillWidth:true}
            CarButton {
                id:rebootPiButton;text:I18n.t("重启树莓派");Layout.fillWidth:true;enabled:!systemTools.powerActionBusy
                contentItem:RowLayout {spacing:Theme.gap
                    MaterialIcon {name:"refresh";Layout.preferredWidth:Theme.icon;Layout.preferredHeight:Theme.icon;light:Theme.textOn(rebootPiButton.buttonColor)==="#ffffff"}
                    Text {text:rebootPiButton.text;font:rebootPiButton.font;color:rebootPiButton.textColor;Layout.fillWidth:true;horizontalAlignment:Text.AlignLeft;verticalAlignment:Text.AlignVCenter}
                }
                onClicked:{pendingPowerAction="reboot";systemActionsDialog.close();powerConfirm.open()}
            }
            CarButton {
                id:powerOffPiButton;text:I18n.t("关闭树莓派");Layout.fillWidth:true;enabled:!systemTools.powerActionBusy
                contentItem:RowLayout {spacing:Theme.gap
                    MaterialIcon {name:"power";Layout.preferredWidth:Theme.icon;Layout.preferredHeight:Theme.icon;light:Theme.textOn(powerOffPiButton.buttonColor)==="#ffffff"}
                    Text {text:powerOffPiButton.text;font:powerOffPiButton.font;color:powerOffPiButton.textColor;Layout.fillWidth:true;horizontalAlignment:Text.AlignLeft;verticalAlignment:Text.AlignVCenter}
                }
                onClicked:{pendingPowerAction="poweroff";systemActionsDialog.close();powerConfirm.open()}
            }
            CarButton {text:I18n.t("取消");Layout.fillWidth:true;onClicked:systemActionsDialog.close()}
        }
        }
    }
    Dialog {
        id:powerConfirm;objectName:"powerConfirmDialog";modal:true;closePolicy:Popup.NoAutoClose
        x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(680*uiScale,win.width-Theme.gap*2)
        height:Math.min(powerContents.implicitHeight+topPadding+bottomPadding,win.height-Theme.gap*2)
         padding:Theme.shapeExtraLarge
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.warning;borderWidth:2}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:powerContents.implicitHeight;boundsBehavior:Flickable.StopAtBounds
        ColumnLayout {
            id:powerContents;width:parent.width;spacing:Theme.gap
            CarText {text:pendingPowerAction==="reboot"?I18n.t("确认重启树莓派？"):I18n.t("确认关闭树莓派？");heading:true;Layout.fillWidth:true;wrapMode:Text.Wrap}
            CarText {text:I18n.t("这会立即中断当前模块连接和所有工作。请先保存文件，并确保可以重新接通电源。");Layout.fillWidth:true;wrapMode:Text.Wrap}
            Flow {Layout.fillWidth:true;spacing:Theme.gap
                CarButton {text:I18n.t("取消");onClicked:powerConfirm.close()}
                CarButton {text:systemTools.powerActionBusy?I18n.t("正在提交…"):pendingPowerAction==="reboot"?I18n.t("确认重启"):I18n.t("确认关机");accent:true;enabled:!systemTools.powerActionBusy
                    onClicked:{const action=pendingPowerAction;powerConfirm.close();systemTools.requestPowerAction(action)}
                }
            }
        }
        }
    }
    Dialog {
        id:browserHistoryDialog;objectName:"browserHistoryDialog"
        modal:true;parent:Overlay.overlay
        width:Math.min(760*uiScale,win.width-Theme.gap*2)
        height:Math.min(520*uiScale,win.height-Theme.gap*2)
        x:(win.width-width)/2;y:(win.height-height)/2
        title:I18n.t("浏览历史")
        onOpened:browserHistory=viperBrowser.recentHistory()
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {
            spacing:Theme.gap
            RowLayout {
                Layout.fillWidth:true
                CarText {text:browserHistory.length+I18n.t(" 项");subdued:true;Layout.fillWidth:true}
                CarButton {text:I18n.t("清除历史");enabled:browserHistory.length>0;onClicked:viperBrowser.clearHistory()}
                IconButton {iconName:"close";label:I18n.t("关闭历史");onClicked:browserHistoryDialog.close()}
            }
            CarText {visible:browserHistory.length===0;text:I18n.t("暂无浏览历史");subdued:true;Layout.fillWidth:true}
            ListView {
                id:browserHistoryList;objectName:"browserHistoryList"
                Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:Theme.gap/2
                model:browserHistory
                boundsBehavior:Flickable.StopAtBounds
                delegate:Rectangle {
                    required property var modelData
                    width:browserHistoryList.width;height:Theme.hit+Theme.gap/2
                    radius:Theme.shapeMedium;color:Theme.surfaceContainer
                    RowLayout {
                        anchors.fill:parent;anchors.margins:Theme.gap/2;spacing:Theme.gap/2
                        ColumnLayout {Layout.fillWidth:true;spacing:2
                            CarText {text:modelData.title||modelData.url;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                            CarText {text:modelData.url;subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle}
                        }
                        IconButton {iconName:"arrow_forward";label:I18n.t("打开历史记录");onClicked:{navigateBrowser(modelData.url);browserHistoryDialog.close()}}
                    }
                }
            }
        }
    }
    Dialog {
        id:browserDownloadsDialog;objectName:"browserDownloadsDialog";modal:true;parent:Overlay.overlay
        x:(win.width-width)/2;y:(win.height-height)/2;width:Math.min(760*uiScale,win.width-Theme.gap*2);height:Math.min(520*uiScale,win.height-Theme.gap*2)
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {spacing:Theme.gap
            RowLayout {Layout.fillWidth:true
                CarText {text:I18n.t("下载管理");heading:true;Layout.fillWidth:true}
                IconButton {iconName:"close";label:I18n.t("关闭");onClicked:browserDownloadsDialog.close()}
            }
            CarText {visible:browserDownloads.length===0;text:I18n.t("暂无下载");subdued:true;Layout.fillWidth:true}
            ListView {Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:Theme.gap/2;model:browserDownloads
                delegate:Rectangle {required property var modelData;required property int index;Layout.fillWidth:true;width:ListView.view.width;height:88*uiScale
                    radius:Theme.shapeSmall;color:Theme.surfaceContainer
                    property var downloadRequest:modelData.request
                    RowLayout {anchors.fill:parent;anchors.margins:Theme.gap/2;spacing:Theme.gap/2
                        ColumnLayout {Layout.fillWidth:true;spacing:2
                            CarText {text:modelData.name;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle}
                            CarText {text:modelData.status+(modelData.total>0?"，"+Math.floor(modelData.received*100/modelData.total)+"%":"");subdued:true;Layout.fillWidth:true;maximumLineCount:1}
                            ProgressBar {visible:modelData.request!==null;Layout.fillWidth:true;from:0;to:Math.max(1,modelData.total);value:modelData.received}
                        }
                        IconButton {visible:!!downloadRequest&&!downloadRequest.isFinished;iconName:downloadRequest&&downloadRequest.isPaused?"play_arrow":"pause";label:downloadRequest&&downloadRequest.isPaused?I18n.t("继续"):I18n.t("暂停");onClicked:if(downloadRequest){if(downloadRequest.isPaused)downloadRequest.resume();else downloadRequest.pause()}}
                        IconButton {visible:!!downloadRequest&&!downloadRequest.isFinished;iconName:"close";label:I18n.t("取消下载");onClicked:if(downloadRequest)downloadRequest.cancel()}
                        IconButton {visible:!downloadRequest;iconName:"delete";label:I18n.t("移除下载记录");onClicked:{let rows=browserDownloads.slice();rows.splice(index,1);browserDownloads=rows}}
                    }
                }
            }
        }
    }
    Dialog {
        id:browserPdfDialog;objectName:"browserPdfDialog";modal:true;parent:Overlay.overlay
        x:(win.width-width)/2;y:(win.height-height)/2;width:Math.min(620*uiScale,win.width-Theme.gap*2)
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {spacing:Theme.gap
            CarText {text:I18n.t("将当前网页保存为 PDF");heading:true;Layout.fillWidth:true}
            CarField {id:browserPdfPath;Layout.fillWidth:true;placeholderText:I18n.t("PDF 文件路径")}
            Flow {Layout.fillWidth:true;spacing:Theme.gap
                CarButton {text:I18n.t("取消");onClicked:browserPdfDialog.close()}
                CarButton {text:I18n.t("保存");accent:true;enabled:browserPdfPath.text.endsWith(".pdf")
                    onClicked:{if(activeBrowser){activeBrowser.printToPdf(browserPdfPath.text);browserStatus=I18n.t("正在生成 PDF");browserPdfDialog.close()}}
                }
            }
        }
    }
    Dialog {
        id:bookmarkDialog;modal:true;x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(760*uiScale,win.width-Theme.gap*2)
        height:Math.min(520*uiScale,win.height-Theme.gap*2);padding:Theme.shapeExtraLarge
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        onOpened:bookmarkFilter=""
        contentItem:Item {
            clip:true
            Flickable {anchors.fill:parent;clip:true;contentWidth:width;contentHeight:bookmarkColumn.implicitHeight;boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
            Column {
                id:bookmarkColumn;width:parent.width;spacing:Theme.gap
                RowLayout {
                    width:bookmarkColumn.width
                    CarText {text:I18n.t("书签");heading:true;Layout.fillWidth:true}
                    CarText {text:browserBookmarks.length+I18n.t(" 项");subdued:true}
                    IconButton {iconName:"close";label:I18n.t("关闭书签");onClicked:bookmarkDialog.close()}
                }
                CarField {id:bookmarkSearch;width:bookmarkColumn.width;placeholderText:I18n.t("搜索网址");text:bookmarkFilter;onTextChanged:bookmarkFilter=text}
                CarText {visible:browserBookmarks.length===0;text:I18n.t("暂无书签。在浏览器中点收藏即可添加。");subdued:true;width:bookmarkColumn.width}
                CarText {visible:browserBookmarks.length>0 && bookmarkList.count===0;text:I18n.t("没有匹配的书签");subdued:true;width:bookmarkColumn.width}
                ListView {
                    id:bookmarkList
                    objectName:"bookmarkList"
                    width:bookmarkColumn.width
                    height:Math.max(120*uiScale,bookmarkDialog.availableHeight-y)
                    clip:true
                    spacing:Theme.gap/2
                    model:browserBookmarks.filter(function(entry){return !bookmarkFilter || entry.url.toLowerCase().indexOf(bookmarkFilter.toLowerCase())>=0})
                    boundsBehavior:Flickable.StopAtBounds
                    delegate:Rectangle {
                        id:bookmarkEntry
                        required property var modelData
                        width:bookmarkList.width;height:Theme.hit+Theme.gap/2
                        radius:Theme.shapeMedium;color:Theme.surfaceContainer
                        RowLayout {
                            anchors.fill:parent;anchors.margins:Theme.gap/2;spacing:Theme.gap/2
                            MaterialIcon {name:"language";Layout.preferredWidth:Theme.icon;Layout.preferredHeight:Theme.icon}
                            CarText {text:bookmarkEntry.modelData.title+"，"+bookmarkEntry.modelData.url;Layout.fillWidth:true;elide:Text.ElideMiddle;maximumLineCount:1}
                            IconButton {iconName:"language";label:I18n.t("打开书签");onClicked:{
                                if(activeBrowser)activeBrowser.url=bookmarkEntry.modelData.url
                                bookmarkDialog.close();go(2)
                            }}
                            IconButton {iconName:"clear";label:I18n.t("删除书签");onClicked:viperBrowser.removeBookmark(bookmarkEntry.modelData.url)}
                        }
                    }
                }
            }
            }
        }
    }
    Dialog {
        id:browserConfigDialog;objectName:"browserConfigDialog";modal:true;parent:Overlay.overlay
        x:(win.width-width)/2;y:(win.height-height)/2
        width:Math.min(760*uiScale,win.width-Theme.gap*2);height:Math.min(560*uiScale,win.height-Theme.gap*2)
        padding:Theme.gap
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {
            spacing:Theme.gap/2
            RowLayout {
                Layout.fillWidth:true
                CarText {text:I18n.t("浏览器设置与扩展");heading:true;Layout.fillWidth:true}
                IconButton {iconName:"close";label:I18n.t("关闭");onClicked:browserConfigDialog.close()}
            }
            TabBar {
                id:browserConfigTabs;Layout.fillWidth:true
                TabButton {text:I18n.t("偏好设置")}
                TabButton {text:I18n.t("广告过滤")}
                TabButton {text:I18n.t("Cookie")}
            }
            StackLayout {currentIndex:browserConfigTabs.currentIndex;Layout.fillWidth:true;Layout.fillHeight:true
                Flickable {clip:true;contentWidth:width;contentHeight:browserPreferenceColumn.implicitHeight;boundsBehavior:Flickable.StopAtBounds
                    ColumnLayout {id:browserPreferenceColumn;width:parent.width;spacing:Theme.gap
                        CarField {id:browserHomePage;Layout.fillWidth:true;placeholderText:I18n.t("主页网址");text:viperBrowser.preferences.homePage
                            onAccepted:{viperBrowser.setPreference("homePage",text);focus=false}}
                        Repeater {model:[
                            {key:"javascript",label:"JavaScript"},{key:"popups",label:"允许弹出窗口"},
                            {key:"images",label:"自动加载图片"},{key:"cookies",label:"启用 Cookie"},
                            {key:"thirdPartyCookies",label:"允许第三方 Cookie"},{key:"sessionCookies",label:"关闭时清除 Cookie"},
                            {key:"doNotTrack",label:"发送 Do Not Track"},{key:"adBlock",label:"启用广告过滤"},
                            {key:"backgroundTabs",label:"后台打开新标签"}
                        ]
                            CheckBox {required property var modelData;Layout.fillWidth:true;Layout.minimumHeight:Theme.hit
                                text:I18n.t(modelData.label);checked:!!viperBrowser.preferences[modelData.key]
                                onToggled:viperBrowser.setPreference(modelData.key,checked)
                            }
                        }
                        CarText {text:I18n.t("搜索引擎");heading:true;Layout.fillWidth:true}
                        RowLayout {Layout.fillWidth:true
                            CarField {id:searchEngineName;Layout.fillWidth:true;placeholderText:I18n.t("名称")}
                            CarField {id:searchEngineTemplate;Layout.fillWidth:true;placeholderText:"https://…?q=%s"}
                            CarButton {text:I18n.t("添加");enabled:searchEngineName.text.length>0&&searchEngineTemplate.text.indexOf("%s")>=0
                                onClicked:if(viperBrowser.addSearchEngine(searchEngineName.text,searchEngineTemplate.text)){searchEngineName.text="";searchEngineTemplate.text=""}}
                        }
                        ListView {Layout.fillWidth:true;Layout.preferredHeight:Math.min(140*uiScale,contentHeight);clip:true;spacing:Theme.gap/4;model:viperBrowser.searchEngines
                            delegate:RowLayout {required property var modelData;Layout.fillWidth:true
                                CheckBox {checked:modelData.default;text:modelData.name;Layout.fillWidth:true;onToggled:if(checked)viperBrowser.setDefaultSearchEngine(modelData.name)}
                                CarText {text:modelData.query;subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle}
                                IconButton {iconName:"delete";label:I18n.t("删除搜索引擎");enabled:viperBrowser.searchEngines.length>1;onClicked:viperBrowser.removeSearchEngine(modelData.name)}
                            }
                        }
                        Flow {Layout.fillWidth:true;spacing:Theme.gap
                            CarButton {text:I18n.t("清除浏览缓存");onClicked:viperBrowser.clearCache()}
                            CarButton {text:I18n.t("保存设置");onClicked:viperBrowser.setPreference("homePage",browserHomePage.text)}
                        }
                    }
                }
                ColumnLayout {spacing:Theme.gap
                    RowLayout {Layout.fillWidth:true
                        CarField {id:filterSubscriptionUrl;Layout.fillWidth:true;placeholderText:"https://…"}
                        CarButton {text:I18n.t("添加订阅");enabled:filterSubscriptionUrl.text.length>0
                            onClicked:{viperBrowser.installSubscription(filterSubscriptionUrl.text);filterSubscriptionUrl.text=""}}
                    }
                    Flow {Layout.fillWidth:true;spacing:Theme.gap
                        CarButton {text:I18n.t("更新全部规则");onClicked:viperBrowser.updateSubscriptions()}
                        CarText {text:viperBrowser.subscriptions.length+I18n.t(" 项");subdued:true}
                    }
                    ListView {Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:Theme.gap/2;model:viperBrowser.subscriptions
                        delegate:Rectangle {required property var modelData;required property int index;Layout.fillWidth:true;width:ListView.view.width;height:64*uiScale
                            radius:Theme.shapeSmall;color:Theme.surfaceContainer
                            RowLayout {anchors.fill:parent;anchors.margins:Theme.gap/2
                                CheckBox {checked:modelData.enabled;onToggled:viperBrowser.toggleSubscription(index)}
                                ColumnLayout {Layout.fillWidth:true;spacing:0
                                    CarText {text:modelData.name;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                    CarText {text:modelData.url;subdued:true;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideMiddle}
                                }
                                IconButton {iconName:"delete";label:I18n.t("删除订阅");onClicked:viperBrowser.removeSubscription(index)}
                            }
                        }
                    }
                }
                ColumnLayout {spacing:Theme.gap
                    RowLayout {Layout.fillWidth:true
                        CarField {id:cookieRaw;Layout.fillWidth:true;placeholderText:I18n.t("Cookie 原始值")}
                        CarField {id:cookieOrigin;Layout.fillWidth:true;placeholderText:"https://example.com"}
                        CarButton {text:I18n.t("添加");enabled:cookieRaw.text.length>0&&cookieOrigin.text.length>0
                            onClicked:if(viperBrowser.setCookie(cookieRaw.text,cookieOrigin.text)){cookieRaw.text=""}}
                    }
                    RowLayout {Layout.fillWidth:true
                        CarText {text:viperBrowser.cookies.length+I18n.t(" 项");subdued:true;Layout.fillWidth:true}
                        CarButton {text:I18n.t("清除全部");onClicked:viperBrowser.clearCookies()}
                    }
                    ListView {Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:Theme.gap/2;model:viperBrowser.cookies
                        delegate:Rectangle {required property var modelData;required property int index;Layout.fillWidth:true;width:ListView.view.width;height:64*uiScale
                            radius:Theme.shapeSmall;color:Theme.surfaceContainer
                            RowLayout {anchors.fill:parent;anchors.margins:Theme.gap/2
                                ColumnLayout {Layout.fillWidth:true;spacing:0
                                    CarText {text:modelData.name+"，"+modelData.domain;Layout.fillWidth:true;maximumLineCount:1;elide:Text.ElideRight}
                                    CarText {text:modelData.path+(modelData.secure?"，Secure":"")+(modelData.httpOnly?"，HttpOnly":"");subdued:true;Layout.fillWidth:true;maximumLineCount:1}
                                }
                                IconButton {iconName:"delete";label:I18n.t("删除 Cookie");onClicked:viperBrowser.deleteCookie(index)}
                            }
                        }
                    }
                }
            }
        }
    }
    Dialog {
        id:browserAuthDialog;objectName:"browserAuthDialog";modal:true;parent:Overlay.overlay;closePolicy:Popup.NoAutoClose
        property string url:"";property string realm:""
        x:(win.width-width)/2;y:(win.height-height)/2;width:Math.min(540*uiScale,win.width-Theme.gap*2)
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {spacing:Theme.gap
            CarText {text:I18n.t("需要网站身份验证");heading:true;Layout.fillWidth:true}
            CarText {text:browserAuthDialog.url+"，"+browserAuthDialog.realm;subdued:true;Layout.fillWidth:true;wrapMode:Text.Wrap}
            CarField {id:browserAuthUser;Layout.fillWidth:true;placeholderText:I18n.t("用户名");onAccepted:browserAuthPassword.forceActiveFocus()}
            CarField {id:browserAuthPassword;Layout.fillWidth:true;placeholderText:I18n.t("密码");echoMode:TextInput.Password;onAccepted:acceptBrowserAuth()}
            Flow {Layout.fillWidth:true;spacing:Theme.gap
                CarButton {text:I18n.t("取消");onClicked:rejectBrowserAuth()}
                CarButton {text:I18n.t("登录");accent:true;onClicked:acceptBrowserAuth()}
            }
        }
        function acceptBrowserAuth(){if(!win.pendingBrowserAuth)return;win.pendingBrowserAuth.request.dialogAccept(browserAuthUser.text,browserAuthPassword.text);win.pendingBrowserAuth=null;browserAuthUser.text="";browserAuthPassword.text="";close()}
        function rejectBrowserAuth(){if(win.pendingBrowserAuth)win.pendingBrowserAuth.request.dialogReject();win.pendingBrowserAuth=null;browserAuthUser.text="";browserAuthPassword.text="";close()}
    }
    Dialog {
        id:browserPermissionDialog;objectName:"browserPermissionDialog";modal:true;parent:Overlay.overlay;closePolicy:Popup.NoAutoClose
        property string origin:"";property int feature:-1
        x:(win.width-width)/2;y:(win.height-height)/2;width:Math.min(560*uiScale,win.width-Theme.gap*2)
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:ColumnLayout {spacing:Theme.gap
            CarText {text:I18n.t("网站权限请求");heading:true;Layout.fillWidth:true}
            CarText {text:browserPermissionDialog.origin+"\n"+browserPermissionName(browserPermissionDialog.feature);Layout.fillWidth:true;wrapMode:Text.Wrap}
            Flow {Layout.fillWidth:true;spacing:Theme.gap
                CarButton {text:I18n.t("拒绝");onClicked:resolveBrowserPermission(false)}
                CarButton {text:I18n.t("允许");accent:true;onClicked:resolveBrowserPermission(true)}
            }
        }
    }
    Dialog {
        id:fileOperationDialog;modal:true;title:({newFile:I18n.t("新建文件"),newFolder:I18n.t("新建文件夹"),rename:I18n.t("重命名"),delete:I18n.t("确认删除")})[fileOperation] || I18n.t("文件操作")
        width:Math.min(600*uiScale,win.width-Theme.gap*2);height:Math.min(400*uiScale,win.height-Theme.gap*2);x:(win.width-width)/2;y:(win.height-height)/2
        padding:Theme.shapeExtraLarge
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:operationContents.implicitHeight
        ColumnLayout {id:operationContents;width:parent.width;spacing:Theme.gap
            CarText {visible:fileOperation==="delete";text:I18n.t("删除 ")+fileSelection+"？";Layout.fillWidth:true;wrapMode:Text.Wrap}
            CarField {id:operationName;visible:fileOperation!=="delete";Layout.fillWidth:true;placeholderText:I18n.t("名称");onAccepted:completeFileOperation()}
            CarText {visible:!!fileOperationError;text:fileOperationError;Layout.fillWidth:true;wrapMode:Text.Wrap;color:Theme.warning}
            Flow {Layout.fillWidth:true;spacing:Theme.gap
                IconButton {iconName:"close";label:I18n.t("取消");onClicked:fileOperationDialog.close()}
                IconButton {iconName:fileOperation==="delete"?"clear":"check";label:fileOperation==="delete"?I18n.t("删除"):I18n.t("确定");filled:true;onClicked:completeFileOperation()}
            }
        }
        }
    }
    Dialog {
        id:fileDialog; modal:true; x:(win.width-width)/2;y:(win.height-height)/2
        property string saveError:""
        onOpened:saveError=""
        width:Math.min(1000*uiScale,win.width-Theme.gap*2);height:win.height-Theme.gap*2;padding:Theme.shapeExtraLarge
        background:GlassSurface {color:Theme.surface;radius:Theme.shapeExtraLarge;borderColor:Theme.outline}
        contentItem:Item {
            ColumnLayout {
                id:editorColumn;anchors.fill:parent;spacing:4
                CarText {text:I18n.t("文件编辑");heading:true;Layout.fillWidth:true}
                CarField {id:editedName;text:filePath;readOnly:true;Layout.fillWidth:true;placeholderText:I18n.t("文件名称")}
                CarText {visible:fileDialog.saveError!=="";text:fileDialog.saveError;Layout.fillWidth:true;wrapMode:Text.Wrap}
                Flow {Layout.fillWidth:true;spacing:Theme.gap
                    IconButton {id:saveFileButton;iconName:"save";label:I18n.t("保存文件");filled:true;enabled:fileEditable;onClicked:{if(systemTools.write(filePath,documentFormatter.serialize(viewer.textDocument,/\.html?$/i.test(filePath)))){refreshFiles();fileDialog.close()}else fileDialog.saveError=I18n.t("保存失败：请检查写入权限、文件路径及 64 KiB 文本大小限制。")}}
                    IconButton {iconName:"tune";label:I18n.t("重命名");enabled:!!fileSelection && !filesRecent;onClicked:{fileDialog.close();requestFileOperation("rename")}}
                    IconButton {iconName:"clear";label:I18n.t("删除文件");enabled:!!fileSelection;onClicked:{fileDialog.close();requestFileOperation("delete")}}
                    IconButton {iconName:"close";label:I18n.t("关闭编辑器");onClicked:fileDialog.close()}
                }
                EditorToolbar {Layout.fillWidth:true;editor:viewer;formatter:documentFormatter;rich:/\.html?$/i.test(filePath);enabled:fileEditable;onSaveRequested:saveFileButton.clicked()}
                ScrollView {Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:80;clip:true
                    ScrollBar.vertical:ScrollBar {
                        implicitWidth:48*uiScale;leftPadding:20*uiScale;rightPadding:20*uiScale;minimumSize:0.2
                        contentItem:Rectangle {implicitWidth:8*uiScale;color:Theme.accent;radius:Theme.shapeSmall}
                    }
                    TextArea {id:viewer;readOnly:!fileEditable;wrapMode:Text.Wrap;textFormat:/\.html?$/i.test(filePath)?TextEdit.RichText:TextEdit.PlainText;selectByMouse:true;persistentSelection:true;font.pointSize:Theme.body;color:textFormat===TextEdit.RichText?"#1f1f1f":Theme.foreground
                        padding:Theme.gap;topPadding:16;bottomPadding:16;topInset:0;bottomInset:0;selectionColor:Theme.accent;selectedTextColor:Theme.accentInk
                        background:Rectangle {color:viewer.textFormat===TextEdit.RichText?"#fffdf8":Theme.background}}
                }
                IconButton {visible:filePath!=="";iconName:"open_external";label:I18n.t("使用系统默认应用打开");onClicked:systemTools.openWithDefault(filePath)
                    contentItem:Item {
                        Rectangle {x:parent.width*0.18;y:parent.height*0.34;width:parent.width*0.48;height:parent.height*0.48;color:"transparent";border.width:2*Theme.scaleFactor;border.color:Theme.foreground;radius:2*Theme.scaleFactor}
                        Rectangle {x:parent.width*0.42;y:parent.height*0.18;width:parent.width*0.43;height:2*Theme.scaleFactor;color:Theme.foreground;rotation:-45;transformOrigin:Item.Right}
                        Rectangle {x:parent.width*0.69;y:parent.height*0.13;width:2*Theme.scaleFactor;height:parent.height*0.34;color:Theme.foreground;rotation:-45}
                        Rectangle {x:parent.width*0.54;y:parent.height*0.08;width:parent.width*0.30;height:2*Theme.scaleFactor;color:Theme.foreground}
                    }
                }
            }
        }
    }
    Dialog {
        id:noteSaveAsDialog;parent:Overlay.overlay;modal:true;title:I18n.t("另存 HTML")
        width:Math.min(560,win.width-32);height:Math.min(noteSaveContents.implicitHeight+implicitHeaderHeight+topPadding+bottomPadding,win.height-32);x:(win.width-width)/2;y:(win.height-height)/2
        property bool overwriteConfirmed:false
        onOpened:{overwriteConfirmed=false;noteSaveError.text=""}
        background:Rectangle {color:Theme.surface;radius:Theme.shapeLarge}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:noteSaveContents.implicitHeight;boundsBehavior:Flickable.StopAtBounds
        Column {id:noteSaveContents;width:parent.width;spacing:5
            TextField {id:noteSaveName;text:"pi-terminal-note.html";width:parent.width;implicitHeight:48;Accessible.name:I18n.t("文件名称");onTextChanged:noteSaveAsDialog.overwriteConfirmed=false}
            CarText {text:I18n.t("纯文本不保留格式，请另存 HTML");width:parent.width;wrapMode:Text.Wrap}
            CarText {id:noteSaveError;visible:text!=="";width:parent.width;wrapMode:Text.Wrap}
            RowLayout {anchors.right:parent.right
                Button {text:I18n.t("取消");implicitHeight:48;onClicked:noteSaveAsDialog.close()}
                Button {text:noteSaveAsDialog.overwriteConfirmed?I18n.t("确认覆盖"):I18n.t("保存文件");implicitHeight:48;onClicked:{
                    const path=noteSaveName.text.trim()
                    if(!/\.html?$/i.test(path)){noteSaveError.text=I18n.t("文件名需以 .html 结尾");return}
                    if(systemTools.fileUrl(path).toString()!==""&&!noteSaveAsDialog.overwriteConfirmed){noteSaveAsDialog.overwriteConfirmed=true;noteSaveError.text=I18n.t("文件已存在，再次点击将覆盖");return}
                    if(saveNote(path))noteSaveAsDialog.close()
                    else noteSaveError.text=notesStatus.text
                }}
            }
        }
        }
    }
    Connections {
        target:systemTools
        function onRemovableDeviceInserted(name) {
            usbInsertDialog.deviceName=name
            const device=systemTools.removableDevices.find(function(d){return d.name===name})
            usbInsertDialog.deviceId=device?device.id:""
            usbInsertDialog.devicePhysical=device?device.physical:""
            usbInsertDialog.open()
        }
        function onRemovableDeviceReady(location) {win.auditPage(3);win.navigateFiles(location)}
        function onRemovableDeviceError(message) {win.notify(I18n.t("USB 设备"),I18n.t(message),false,I18n.t("文件"),"storage")}
        function onRemovableDevicesChanged() {
            if(usbInsertDialog.visible&&!systemTools.removableDevices.some(function(d){return d.id===usbInsertDialog.deviceId})){
                const replacement=systemTools.removableDevices.find(function(d){return d.physical===usbInsertDialog.devicePhysical})
                if(replacement){usbInsertDialog.deviceId=replacement.id;usbInsertDialog.deviceName=replacement.name}
                else usbInsertDialog.close()
            }
            if(folder.indexOf("@usb/")!==0)return
            const root=folder.split('/').slice(0,2).join('/')
            if(!systemTools.removableDevices.some(function(d){return d.location===root&&d.mounted})) {
                win.navigateFiles("");win.notify(I18n.t("USB 设备"),I18n.t("USB 设备已移除。"),false,I18n.t("文件"),"storage")
            }
        }
    }
    Dialog {
        id:usbInsertDialog;objectName:"usbInsertDialog";parent:Overlay.overlay;modal:false
        property string deviceName:""
        property string deviceId:""
        property string devicePhysical:""
        title:I18n.t("检测到 USB 存储设备")
        width:Math.min(460,win.width-32);height:Math.min(usbInsertContents.implicitHeight+implicitHeaderHeight+topPadding+bottomPadding,win.height-32);x:(win.width-width)/2;y:(win.height-height)/2
        background:Rectangle {color:Theme.surface;radius:Theme.shapeLarge;border.color:Theme.outline}
        contentItem:Flickable {clip:true;contentWidth:width;contentHeight:usbInsertContents.implicitHeight;boundsBehavior:Flickable.StopAtBounds
        Column {id:usbInsertContents;width:parent.width;spacing:5
            CarText {text:usbInsertDialog.deviceName;width:parent.width;maximumLineCount:2;elide:Text.ElideRight}
            RowLayout {anchors.right:parent.right
                Button {text:I18n.t("稍后");implicitHeight:48;onClicked:usbInsertDialog.close()}
                Button {text:I18n.t("打开设备");implicitHeight:48;onClicked:{usbInsertDialog.close();systemTools.openRemovableDevice(usbInsertDialog.deviceId)}}
            }
        }
        }
    }
    TextFormatter {id:documentFormatter}
    PictureViewer { id:pictureViewer; parent:Overlay.overlay }
    Component.onCompleted:{
        observedWallpaperUrl=systemTools.wallpaper.toString()
        observedUiLanguage=systemTools.uiLanguage
        browserBookmarks=viperBrowser.bookmarks();syncCards()
        const prefs=viperBrowser.preferences
        if(prefs.startupMode===3){
            const saved=viperBrowser.savedSession
            if(saved.tabs && saved.tabs.length){tabs.clear();for(let i=0;i<saved.tabs.length && i<8;++i)tabs.append({address:saved.tabs[i].address || "about:blank",pageTitle:saved.tabs[i].pageTitle || "",privateMode:false});browserTabs.currentIndex=Math.max(0,Math.min(tabs.count-1,saved.currentIndex||0))}
        } else if(prefs.startupMode===1)tabs.setProperty(0,"address","about:blank")
        else if(prefs.startupMode===2)tabs.setProperty(0,"address",viperBrowser.newTabUrl())
        else if(prefs.homePage)tabs.setProperty(0,"address",prefs.homePage)
        startupInterfaceReady=true
        if(connectionManager.bridgeMonitoring && connectionManager.bridgeConnected)
            Qt.callLater(showBridgeConnectedPrompt)
    }
}
