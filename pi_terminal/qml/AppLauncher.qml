import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Terminal.Native 1.0

Item {
    id:root
    property var model
    property int revision:0
    property Item backgroundSource
    property Item backgroundBlurTexture
    readonly property bool efficientRendering:systemTools.energySaving
    // Larger app cards leave room for a visible 3D turn while paging.
    readonly property int columns:Math.max(2,Math.min(3,Math.floor(width/(260*Theme.scaleFactor))))
    readonly property int rows:Math.max(1,Math.min(2,Math.floor((height-24*Theme.scaleFactor)/(170*Theme.scaleFactor))))
    readonly property int capacity:columns*rows
    readonly property int pageCount:Math.max(1,Math.ceil((model?model.count:0)/capacity))
    property alias currentIndex:view.currentIndex
    property alias contentX:view.contentX
    signal activated(var entry,real originX,real originY)
    // 访客会话里灰显的入口：不启动，只交给宿主弹"无权限"。
    signal restrictedActivated(var entry)

    // ---- 编辑模式：长按拖动排序（只作用于内置应用，模块卡片固定在页首）----
    property var defaultOrder: []          // Main 传入的内置应用默认 entryId 顺序
    property bool editMode: false
    property bool dragActive: false
    property int dragIndex: -1
    property var dragPoint: Qt.point(0, 0)
    property var dragEntry: ({})
    property var editSnapshot: []

    function firstAppIndex() {
        let i = 0
        if (!model) return 0
        while (i < model.count && model.get(i).route === 5) ++i
        return i
    }
    function snapshotOrder() {
        const ids = []
        for (let i = 0; i < (model ? model.count : 0); ++i) ids.push(model.get(i).entryId)
        return ids
    }
    // 按 ids 重排整个模型；ids 里不存在或模型里不存在的项保持相对位置。
    function applyOrder(ids) {
        if (!model) return
        let target = 0
        for (let id of ids) {
            let found = -1
            for (let i = target; i < model.count; ++i) if (model.get(i).entryId === id) { found = i; break }
            if (found < 0) continue
            if (found !== target) model.move(found, target, 1)
            ++target
        }
        revision++
    }
    function enterEdit() {
        editSnapshot = snapshotOrder()
        dragActive = false
        editMode = true
    }
    function cancelEdit() {
        applyOrder(editSnapshot)
        dragActive = false
        editMode = false
    }
    function finishEdit() {
        const ids = []
        const first = firstAppIndex()
        for (let i = first; i < (model ? model.count : 0); ++i) ids.push(model.get(i).entryId)
        systemTools.settingsWrite("layout/apps", JSON.stringify(ids))
        dragActive = false
        editMode = false
    }
    function resetOrder() {
        if (!defaultOrder || defaultOrder.length === 0) return
        const modules = []
        const first = firstAppIndex()
        for (let i = 0; i < first; ++i) modules.push(model.get(i).entryId)
        applyOrder(modules.concat(defaultOrder))
    }
    function beginDrag(index, sceneX, sceneY) {
        if (!model || index < firstAppIndex() || index >= model.count) return
        dragIndex = index
        dragEntry = entryAt(index)
        const p = root.mapFromItem(null, sceneX, sceneY)
        dragPoint = Qt.point(p.x, p.y)
        dragActive = true
    }
    function updateDrag(sceneX, sceneY) {
        if (!dragActive) return
        const p = root.mapFromItem(null, sceneX, sceneY)
        dragPoint = Qt.point(p.x, p.y)
        moveDragTo(targetIndexAt(p.x, p.y))
        // 拖到左右边缘停留 → 自动翻页继续拖。
        const edge = 48 * Theme.scaleFactor
        if (p.x < edge && view.currentIndex > 0) edgeFlipTimer.start()
        else if (p.x > width - edge && view.currentIndex < pageCount - 1) edgeFlipTimer.start()
        else edgeFlipTimer.stop()
    }
    function endDrag() {
        dragActive = false
        dragIndex = -1
        edgeFlipTimer.stop()
    }
    function targetIndexAt(x, y) {
        if (!model || capacity <= 0) return -1
        const tileW = Math.max(1, view.width / columns)
        const tileH = Math.max(1, view.height / rows)
        const col = Math.max(0, Math.min(columns - 1, Math.floor(x / tileW)))
        const row = Math.max(0, Math.min(rows - 1, Math.floor(y / tileH)))
        let target = view.currentIndex * capacity + row * columns + col
        target = Math.max(firstAppIndex(), Math.min(model.count - 1, target))
        return target
    }
    function moveDragTo(target) {
        if (!model) return
        // 无论来自指针还是测试/脚本，都不允许把内置应用拖到模块卡片前面。
        target = Math.max(firstAppIndex(), Math.min(model.count - 1, target))
        if (target === dragIndex) return
        model.move(dragIndex, target, 1)
        dragIndex = target
        dragEntry = entryAt(target)
        revision++
    }

    Timer {
        id: edgeFlipTimer
        interval: 600; repeat: false
        onTriggered: {
            if (!root.dragActive) return
            if (root.dragPoint.x < 48 * Theme.scaleFactor && view.currentIndex > 0)
                view.decrementCurrentIndex()
            else if (root.dragPoint.x > root.width - 48 * Theme.scaleFactor && view.currentIndex < root.pageCount - 1)
                view.incrementCurrentIndex()
            else return
            Qt.callLater(function() { root.moveDragTo(root.targetIndexAt(root.dragPoint.x, root.dragPoint.y)) })
        }
    }

    FontMetrics {id:titleMetrics;font.pointSize:Theme.title}
    FontMetrics {id:bodyMetrics;font.pointSize:Theme.body}
    function entryAt(index) {
        if(!model || index<0 || index>=model.count) return {entryId:"",title:"",description:"",category:"",accentColor:"#85deff",iconName:"extension",route:0,instance:"",ready:false}
        let e=model.get(index)
        return {entryId:e.entryId,title:e.title,description:e.description,category:e.category,accentColor:e.accentColor,iconName:e.iconName,route:e.route,instance:e.instance,ready:e.ready,restricted:e.restricted===true}
    }
    function reveal(instance) {
        for(let i=0;i<(model?model.count:0);++i) if(model.get(i).instance===instance) {view.currentIndex=Math.floor(i/capacity);return}
    }
    onPageCountChanged:if(view.currentIndex>=pageCount)view.currentIndex=pageCount-1
    Flickable {
        id:vertical;objectName:"homePage";anchors.fill:parent;clip:true
        interactive:!root.editMode
        contentWidth:width;contentHeight:Math.max(height,root.rows*170*Theme.scaleFactor+48*Theme.scaleFactor)
        boundsBehavior:Flickable.StopAtBounds;flickableDirection:Flickable.VerticalFlick
        ListView {
            id:view;objectName:"homeCarousel";width:parent.width;height:vertical.contentHeight-48*Theme.scaleFactor
            interactive:!root.editMode
            orientation:ListView.Horizontal;clip:true;model:root.pageCount
            snapMode:ListView.SnapOneItem;boundsBehavior:Flickable.StopAtBounds
            highlightRangeMode:ListView.StrictlyEnforceRange;preferredHighlightBegin:0;preferredHighlightEnd:width
            highlightMoveDuration:240;maximumFlickVelocity:2000*Theme.scaleFactor;flickDeceleration:2800*Theme.scaleFactor
            focus:true
            Keys.onLeftPressed:decrementCurrentIndex()
            Keys.onRightPressed:incrementCurrentIndex()
            delegate:Item {
                id:page;required property int index;width:view.width;height:view.height
                Repeater {
                    model:root.capacity
                    delegate:Item {
                        id:tile;objectName:"appTile";required property int index
                        property var entry:{let changed=root.revision;return root.entryAt(page.index*root.capacity+index)}
                        property string entryId:entry.entryId
                        // 访客会话的禁用入口：灰显、带锁、点击只弹"无权限"。
                        property bool restricted:entry.restricted===true
                        property bool auditTile:true
                         width:page.width/root.columns
                         height:page.height/root.rows
                         x:(index%root.columns)*width
                         y:Math.floor(index/root.columns)*height
                        visible:entryId!==""
                         property real pageOffset:(page.x-view.contentX)/Math.max(1,view.width)
                         property real rotationDegrees:Math.max(-54,Math.min(54,-pageOffset*54))
                         property real depthScale:1-Math.min(0.1,Math.abs(pageOffset)*0.1)
                         property real iconSize:Math.min(100*Theme.scaleFactor,Math.max(68*Theme.scaleFactor,height-titleMetrics.height-bodyMetrics.height-Theme.gap*3))
                         Behavior on rotationDegrees { NumberAnimation { duration:180; easing.type:Easing.OutCubic } }
                         Behavior on depthScale { NumberAnimation { duration:180; easing.type:Easing.OutCubic } }
                        function launch() {
                            if (restricted) { root.restrictedActivated(entry); return }
                            let point=iconSurface.mapToItem(null,iconSurface.width/2,iconSurface.height/2)
                            root.activated(entry,point.x,point.y)
                        }
                        activeFocusOnTab:true
                        Keys.onReturnPressed:launch()
                        Accessible.role:Accessible.Button;Accessible.name:entry.title+" "+(restricted?I18n.t("无权限"):entry.description)
                        Accessible.onPressAction:launch()
                         transform: [
                             Rotation { id:cardRotation;objectName:"cardYRotation"; origin.x:tile.width/2; origin.y:tile.height/2; axis.x:0; axis.y:1; axis.z:0; angle:tile.rotationDegrees },
                             Scale { id:cardScale;origin.x:tile.width/2; origin.y:tile.height/2; xScale:tile.depthScale; yScale:tile.depthScale }
                         ]
                          ShaderEffectSource {
                              id:cardBackdrop;objectName:"launcherCardBackdrop";parent:root.backgroundSource?root.backgroundSource.parent:tile;z:-99;sourceItem:root.backgroundBlurTexture?null:root.backgroundSource;width:1;height:1;live:true
                             sourceRect:{
                                if(!root.backgroundSource)return Qt.rect(0,0,1,1)
                                const geometry=tile.x+tile.y+page.x+page.y+view.contentX+vertical.contentY+cardRotation.angle+cardScale.xScale+cardScale.yScale
                                if(!isFinite(geometry))return Qt.rect(0,0,1,1)
                                 const center=tile.mapToItem(root.backgroundSource,tile.width/2,tile.height/2)
                                 return Qt.rect(center.x-tile.width/2,center.y-tile.height/2,tile.width,tile.height)
                             }
                            textureSize:Qt.size(Math.max(1,tile.width*(efficientRendering?0.5:1)),Math.max(1,tile.height*(efficientRendering?0.5:1)))
                        }
                           CachedBlur {objectName:"launcherBackdropBlur";visible:!view.moving;anchors.fill:parent;source:root.backgroundBlurTexture||cardBackdrop
                               preblurred:root.backgroundBlurTexture!==null
                               sourceRect:root.backgroundBlurTexture?Qt.rect(cardBackdrop.sourceRect.x/root.backgroundBlurTexture.width,cardBackdrop.sourceRect.y/root.backgroundBlurTexture.height,cardBackdrop.sourceRect.width/root.backgroundBlurTexture.width,cardBackdrop.sourceRect.height/root.backgroundBlurTexture.height):Qt.rect(0,0,1,1)
                               levels:systemTools.energySaving?2:4;strength:2;mixAmount:1;resolutionScale:root.backgroundBlurTexture?root.backgroundBlurTexture.resolutionScale:systemTools.energySaving?0.25:0.5;cornerRadius:Theme.shapeExtraLarge}
                        Item {
                            objectName:"launcherCardChrome"
                            anchors.fill:parent
                              visible:true
                             anchors.margins:6*Theme.scaleFactor
                              opacity:systemTools.launcherOpacity*(tile.restricted?0.55:1)
                            layer.enabled:!efficientRendering
                            Rectangle {
                                id:cardSurface
                                objectName:"launcherCardSurface"
                                anchors.fill:parent
                                radius:Theme.shapeExtraLarge
                                property int outlineWidth:page.index===view.currentIndex?2:1
                              color:efficientRendering?Theme.surfaceContainer:Qt.rgba(Theme.surfaceContainer.r,Theme.surfaceContainer.g,Theme.surfaceContainer.b,0.72)
                                border.width:outlineWidth
                                border.color:page.index===view.currentIndex?Theme.accent:Theme.outlineVariant
                            }
                            BlurItem {
                                objectName:"launcherCardBlur"
                                visible:!efficientRendering&&!view.moving
                                anchors.fill:cardSurface
                                source:cardSurface
                                levels:1;strength:0.35;mixAmount:0.12;opacity:0.9
                            }
                        }
                        Column {
                            anchors.centerIn:parent;width:parent.width;spacing:Theme.gap*1.25
                            // 访客禁用入口整组降低不透明度，配合去色图标形成"灰卡"。
                            opacity:tile.restricted?0.55:1
                            Item {
                                objectName:"launcherLogo"
                                width:tile.iconSize;height:width;anchors.horizontalCenter:parent.horizontalCenter
                                scale:tap.pressed?0.94:1
                                Behavior on scale {NumberAnimation{duration:90}}
                                 AppIcon {id:iconSurface;anchors.fill:parent;iconName:tile.entry.iconName;accentColor:tile.restricted?Theme.disabledText:tile.entry.accentColor;layer.enabled:!efficientRendering}
                                // Blend a shallow GPU blur with 90% of the original glyph. Labels stay sharp.
                                 BlurItem {objectName:"launcherIconBlur";visible:false;anchors.fill:parent;source:iconSurface;levels:1;strength:0.35;mixAmount:0.10}
                                Rectangle {anchors.fill:parent;anchors.margins:-5*Theme.scaleFactor;radius:Theme.shapeFull;color:"transparent"
                                    border.width:tile.activeFocus?2:0;border.color:Theme.accent}
                                Rectangle {
                                    opacity:systemTools.launcherOpacity;visible:tile.entry.instance!=="";width:32*Theme.scaleFactor;height:width;radius:Theme.shapeFull
                                    anchors.right:parent.right;anchors.bottom:parent.bottom;color:Theme.surface
                                    MaterialIcon {anchors.centerIn:parent;width:24*Theme.scaleFactor;height:width;name:tile.entry.ready?"check":"refresh"}
                                }
                            }
                             CarText {id:nameText;objectName:"launcherTitle";width:parent.width;height:titleMetrics.height;text:tile.entry.title;heading:true;horizontalAlignment:Text.AlignHCenter
                                maximumLineCount:1;elide:Text.ElideRight}
                              CarText {id:descriptionText;objectName:"launcherDescription";visible:tile.entry.instance!=="";width:parent.width;height:bodyMetrics.height;text:tile.entry.description;subdued:true
                                 Accessible.ignored:tile.entry.instance==="";horizontalAlignment:Text.AlignHCenter;maximumLineCount:1;elide:Text.ElideRight}
                        }
                        TapHandler {id:tap;enabled:!root.editMode;gesturePolicy:TapHandler.DragThreshold;onTapped:tile.launch()}
                        // 访客禁用入口右上角的锁；不随卡片内容一起变透明。
                        Rectangle {
                            objectName:"restrictedLock"
                            visible:tile.restricted
                            z:2
                            width:32*Theme.scaleFactor;height:width;radius:Theme.shapeFull
                            anchors.right:parent.right;anchors.top:parent.top
                            anchors.margins:12*Theme.scaleFactor
                            color:Theme.surface
                            border.width:1;border.color:Theme.outlineVariant
                            MaterialIcon {anchors.centerIn:parent;width:20*Theme.scaleFactor;height:width;name:"lock"}
                        }
                        // 编辑模式：长按/拖动内置应用换位；模块卡片（route=5）不参与。
                        DragHandler {
                            id:tileDrag
                            enabled:root.editMode && tile.entry.instance==="" && tile.entry.route!==5
                            target:null
                            dragThreshold:0
                            grabPermissions:PointerHandler.CanTakeOverFromAnything
                            onActiveChanged:{
                                if(active){
                                    const p=centroid.scenePosition
                                    root.beginDrag(page.index*root.capacity+index,p.x,p.y)
                                } else if(root.dragActive) root.endDrag()
                            }
                            onCentroidChanged:{
                                if(!active)return
                                const p=centroid.scenePosition
                                root.updateDrag(p.x,p.y)
                            }
                        }
                        // 安卓式抖动：仅编辑态、非拖拽中。
                        SequentialAnimation on rotation {
                            running:root.editMode && !root.dragActive
                            loops:Animation.Infinite
                            NumberAnimation{from:-0.7;to:0.7;duration:320;easing.type:Easing.InOutSine}
                            NumberAnimation{from:0.7;to:-0.7;duration:320;easing.type:Easing.InOutSine}
                        }
                    }
                }
            }
        }
        // 编辑控件在 Main 的顶栏（homeHeader），这里只保留翻页导航。
        RowLayout {
            visible:root.pageCount>1
            anchors.top:view.bottom;anchors.horizontalCenter:parent.horizontalCenter;height:64*Theme.scaleFactor;spacing:Theme.gap
            IconButton {visible:root.width>420*Theme.scaleFactor;iconName:"chevron_left";label:I18n.t("上一页应用");enabled:view.currentIndex>0;onClicked:view.decrementCurrentIndex()}
            CarText {text:(view.currentIndex+1)+" / "+root.pageCount;subdued:true;horizontalAlignment:Text.AlignHCenter}
            IconButton {visible:root.width>420*Theme.scaleFactor;iconName:"chevron_right";label:I18n.t("下一页应用");enabled:view.currentIndex<root.pageCount-1;onClicked:view.incrementCurrentIndex()}
        }
    }

    // 拖拽浮层：只画一张简化卡片，不复用/修改模糊与渲染组件。
    Rectangle {
        id:dragGhost
        parent:root
        visible:root.dragActive
        width:Math.max(80*Theme.scaleFactor,view.width/Math.max(1,root.columns)*0.82)
        height:Math.max(80*Theme.scaleFactor,view.height/Math.max(1,root.rows)*0.82)
        x:root.dragPoint.x-width/2
        y:root.dragPoint.y-height/2
        radius:Theme.shapeExtraLarge
        color:Theme.surfaceContainerHigh
        border.width:2
        border.color:Theme.accent
        opacity:0.96
        z:100
        Column {
            anchors.centerIn:parent
            spacing:Theme.gap/2
            AppIcon {
                width:72*Theme.scaleFactor;height:width
                anchors.horizontalCenter:parent.horizontalCenter
                iconName:root.dragEntry.iconName||"extension"
                accentColor:root.dragEntry.accentColor||Theme.accent
            }
            CarText {
                anchors.horizontalCenter:parent.horizontalCenter
                text:root.dragEntry.title||""
                heading:true
            }
        }
    }
}
