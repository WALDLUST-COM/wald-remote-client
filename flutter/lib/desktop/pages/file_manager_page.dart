import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:extended_text/extended_text.dart';
import 'package:flutter_hbb/common/wald_local_open.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/desktop/widgets/dragable_divider.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/desktop/widgets/list_search_action_listener.dart';
import 'package:flutter_hbb/desktop/widgets/menu_button.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/web/dummy.dart'
    if (dart.library.html) 'package:flutter_hbb/web/web_unique.dart';

import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar
}

/// The status of currently focused scope of the mouse
enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none
}

// Waldlust(DSK-07): 디자인 미리보기(test/wald_preview.dart)는 연결 없이 화면만 띄운다.
@visibleForTesting
bool waldFileManagerPreview = false;

// Waldlust(DSK-07, 부록 A-36): 로컬·원격 목록 : 전송 목록 너비 몫. 전에는 3:3:2(전송 목록 25%) — 22% 로 줄여
// 파일 목록에 너비를 준다.
const int _kWaldFilePanelFlex = 7;
const int _kWaldStatusFlex = 4;
// 수정일(초까지, 12px·숫자 고정폭 약 116)·크기('1023.9 KB' 약 52 + 오른쪽 여백) 칸의 처음 너비. 남는 너비는 이름 칸.
const double _kWaldModifiedColWidth = 128;
const double _kWaldSizeColWidth = 72;

class FileManagerPage extends StatefulWidget {
  FileManagerPage(
      {Key? key,
      required this.id,
      required this.password,
      required this.isSharedPassword,
      this.tabController,
      this.connToken,
      this.forceRelay})
      : super(key: key);
  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final DesktopTabController? tabController;
  final SimpleWrapper<State<FileManagerPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _FileManagerPageState)._ffi;

  @override
  State<StatefulWidget> createState() {
    final state = _FileManagerPageState();
    _lastState.value = state;
    return state;
  }
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);

  final _dropMaskVisible = false.obs; // TODO impl drop mask
  final _overlayKeyState = OverlayKeyState();
  final _uniqueKey = UniqueKey();
  // Waldlust(DSK-07): 내 파일 목록에 놓은 경로로 옮길 때 쓴다(부록 A-37).
  final _localViewKey = GlobalKey<_FileManagerViewState>();

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;
  JobController get jobController => model.jobController;

  @override
  void initState() {
    super.initState();
    _ffi = FFI(null);
    if (waldFileManagerPreview) {
      Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
      _ffi.dialogManager.setOverlayState(_overlayKeyState);
      return;
    }
    _ffi.start(widget.id,
        isFileTransfer: true,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        connToken: widget.connToken,
        forceRelay: widget.forceRelay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    Get.put<FFI>(_ffi, tag: 'ft_${widget.id}');
    WakelockManager.enable(_uniqueKey);
    if (isWeb) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    debugPrint("File manager page init success with id ${widget.id}");
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
      Get.delete<FFI>(tag: 'ft_${widget.id}');
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      jobController.jobTable.refresh();
    }
  }

  Widget willPopScope(Widget child) {
    if (isWeb) {
      return WillPopScope(
        onWillPop: () async {
          clientClose(_ffi.sessionId, _ffi);
          return false;
        },
        child: child,
      );
    } else {
      return child;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(key: _overlayKeyState.key, initialEntries: [
      OverlayEntry(builder: (_) {
        return willPopScope(Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Row(
            children: [
              if (!isWeb)
                Flexible(
                    flex: _kWaldFilePanelFlex,
                    child: dropArea(FileManagerView(
                        model.localController, _ffi, _mouseFocusScope,
                        key: _localViewKey))),
              Flexible(
                  flex: _kWaldFilePanelFlex,
                  child: dropArea(FileManagerView(
                      model.remoteController, _ffi, _mouseFocusScope))),
              Flexible(flex: _kWaldStatusFlex, child: statusList())
            ],
          ),
        ));
      })
    ]);
  }

  Widget dropArea(FileManagerView fileView) {
    return DropTarget(
        onDragDone: (detail) =>
            handleDragDone(detail, fileView.controller.isLocal),
        onDragEntered: (enter) {
          _dropMaskVisible.value = true;
        },
        onDragExited: (exit) {
          _dropMaskVisible.value = false;
        },
        child: fileView);
  }

  Widget generateCard(Widget child) {
    return Container(
      // Waldlust(DSK-07, 부록 A-36): 어드민 카드(흰 바탕·n200 테두리·둥글기 12). 전에는 n100·둥글기 15.
      decoration: waldCardDecoration(),
      child: child,
    );
  }

  /// transfer status list
  /// watch transfer status
  Widget statusList() {
    // Waldlust(DSK-07, 부록 A-36): 상태색 — 오류 빨강·일시정지 주황·완료 초록(취소·건너뜀은 회색),
    // 그 밖은 아이콘 검정·글자 회색. 판정은 JobProgress.display() 와 같다.
    Color stateColor(JobProgress job, {bool text = false}) {
      switch (job.state) {
        case JobState.error:
          return WaldPalette.red600;
        case JobState.paused:
          return WaldPalette.amber600;
        case JobState.done:
          if (job.err == 'cancel' || job.err == 'skipped') {
            return WaldPalette.neutral500;
          }
          return text ? WaldPalette.green700 : WaldPalette.green600;
        default:
          return text ? WaldPalette.neutral500 : WaldPalette.neutral900;
      }
    }

    Widget getIcon(JobProgress job) {
      final color = stateColor(job);
      switch (job.type) {
        case JobType.deleteDir:
        case JobType.deleteFile:
          return Icon(waldIcon(Icons.delete_outline), color: color);
        default:
          // Waldlust(DSK-07): '<'·'>' 화살표 대신 받기·보내기 아이콘.
          return Icon(
              waldIcon(job.isRemoteToLocal ? Icons.download : Icons.upload),
              color: color);
      }
    }

    // Waldlust(DSK-07): 전체 경로 대신 마지막 이름만 보인다(툴팁은 전체 경로).
    // 원격이 Windows 면 '\' 로 나뉘어 path.basename 으로는 못 자른다.
    String displayName(JobProgress job) {
      final parts = job.jobName.split(RegExp(r'[\\/]'))
        ..removeWhere((e) => e.isEmpty);
      return parts.isEmpty ? job.jobName : parts.last;
    }

    statusListView(List<JobProgress> jobs) => ListView.builder(
          controller: ScrollController(),
          itemBuilder: (BuildContext context, int index) {
            final item = jobs[index];
            final status = item.getStatus();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: generateCard(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        getIcon(item)
                            .marginSymmetric(horizontal: 10, vertical: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                waitDuration: Duration(milliseconds: 500),
                                message: item.jobName,
                                child: ExtendedText(
                                  displayName(item),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w500),
                                  overflowWidget: TextOverflowWidget(
                                      child: Text("..."),
                                      position: TextOverflowPosition.start),
                                ),
                              ),
                              Tooltip(
                                waitDuration: Duration(milliseconds: 500),
                                message: status,
                                child: Text(status,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: stateColor(item, text: true),
                                    )).marginOnly(top: 6),
                              ),
                              // Waldlust(DSK-07, 부록 A-36): 30px 막대 가운데 % → 얇은 막대 + 오른쪽 %.
                              Offstage(
                                offstage: item.type != JobType.transfer ||
                                    item.state != JobState.inProgress,
                                child: LinearPercentIndicator(
                                  animateFromLastPercent: true,
                                  padding: EdgeInsets.zero,
                                  trailing: SizedBox(
                                    width: 44,
                                    child: Text(
                                      item.percentText,
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontSize: WaldSize.smallFont,
                                        color: WaldPalette.neutral600,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                  ),
                                  barRadius: Radius.circular(3),
                                  percent: item.percent,
                                  progressColor: MyTheme.accent,
                                  backgroundColor: Theme.of(context).hoverColor,
                                  lineHeight: 6,
                                ).paddingOnly(top: 8),
                              ),
                              _waldReceivedActions(item),
                            ],
                            // Waldlust(DSK-07): 진행 막대·열기 버튼으로 카드가 높아져도 파일명 위 여백이
                            // 짧은 카드(오른쪽 버튼 높이 68 의 가운데)와 같게 위아래 15 를 둔다.
                          ).paddingSymmetric(vertical: 15),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            // Waldlust(DSK-07): 재개·삭제는 툴바와 같은 어두운 알약.
                            Offstage(
                              offstage: item.state != JobState.paused,
                              child: MenuButton(
                                tooltip: translate("Resume"),
                                onPressed: () {
                                  jobController.resumeJob(item.id);
                                },
                                child: waldSvg("assets/refresh.svg",
                                    color: Colors.white),
                                color: WaldPalette.neutral800,
                                hoverColor: WaldPalette.neutral700,
                              ),
                            ),
                            MenuButton(
                              tooltip: translate("Delete"),
                              child: waldSvg("assets/close.svg",
                                  color: Colors.white),
                              onPressed: () {
                                jobController.jobTable.removeAt(index);
                                jobController.cancelJob(item.id);
                              },
                              color: WaldPalette.neutral800,
                              hoverColor: WaldPalette.neutral700,
                            ),
                          ],
                        ).marginAll(12),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          itemCount: jobController.jobTable.length,
        );

    return PreferredSize(
      preferredSize: const Size(200, double.infinity),
      child: Container(
          margin: const EdgeInsets.only(top: 16.0, bottom: 16.0, right: 16.0),
          padding: const EdgeInsets.all(8.0),
          child: Obx(
            () => jobController.jobTable.isEmpty
                ? generateCard(
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        // Waldlust(DSK-07, 부록 A-36): 빈 상태는 옅게(아이콘 n400·글자 n500, 1.2 배율 뺌).
                        children: [
                          waldSvg("assets/transfer.svg",
                                  color: WaldPalette.neutral400,
                                  height: 40,
                                  iconSize: 32)
                              .paddingOnly(bottom: 10),
                          Text(
                            translate("No transfers in progress"),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: WaldPalette.neutral500),
                          ),
                        ],
                      ),
                    ),
                  )
                : statusListView(jobController.jobTable),
          )),
    );
  }

  /// Waldlust(DSK-08): 받기가 끝난 항목의 [파일 열기]·[폴더 열기].
  /// 실행 파일과 폴더는 [폴더 열기]만 둔다(명세 Q-16 (c)).
  Widget _waldReceivedActions(JobProgress job) {
    if (isWeb ||
        job.type != JobType.transfer ||
        !job.isRemoteToLocal ||
        job.state != JobState.done ||
        job.err == 'cancel' ||
        job.to.isEmpty) {
      return const SizedBox.shrink();
    }
    final type = FileSystemEntity.typeSync(job.to);
    if (type == FileSystemEntityType.notFound) {
      return const SizedBox.shrink();
    }
    final canOpen =
        type == FileSystemEntityType.file && !waldIsExecutable(job.to);
    Widget button(IconData icon, String label, VoidCallback onPressed) =>
        OutlinedButton.icon(
          onPressed: onPressed,
          style: const ButtonStyle(
            padding:
                WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
            minimumSize: WidgetStatePropertyAll(Size(0, 28)),
            iconSize: WidgetStatePropertyAll(14),
            textStyle: WidgetStatePropertyAll(TextStyle(
                fontSize: WaldSize.smallFont, fontWeight: FontWeight.w500)),
          ),
          icon: Icon(waldIcon(icon)),
          label: Text(translate(label),
              strutStyle: waldButtonStrut(WaldSize.smallFont)),
        );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (canOpen)
          button(Icons.launch_outlined, 'Open file',
              () => waldOpenLocalFile(job.to)),
        button(Icons.folder_open, 'Open folder',
            () => waldRevealLocalPath(job.to)),
      ],
    ).marginOnly(top: 8);
  }

  void handleDragDone(DropDoneDetails details, bool isLocal) {
    if (isLocal) {
      // Waldlust(DSK-07): 내 파일 목록에 놓으면 그 경로로 옮긴다(부록 A-37).
      _localViewKey.currentState?.waldOpenDropped(details);
      return;
    }
    // Waldlust(DSK-07): 원격 목록에 놓은 내 파일(Finder·탐색기에서 끌어 온 것)은 확인 창을 거쳐
    // 원격의 지금 폴더로 보낸다. 2026-10-16 오전송 우려로 막았다가(부록 A-37) 2026-11-26 사용자
    // 결정으로 확인 창을 붙여 되살렸다. 업스트림은 원격 쪽 항목으로 만들어 그 경로를 원격에서
    // 받아 왔다(0c5d7027f).
    _waldSendDropped(details);
  }

  Future<void> _waldSendDropped(DropDoneDetails details) async {
    final items = SelectedItems(isLocal: true);
    for (var file in details.files) {
      final type = FileSystemEntity.typeSync(file.path);
      if (type == FileSystemEntityType.notFound) continue;
      items.add(Entry()
        ..path = file.path
        ..name = file.name
        ..size = type == FileSystemEntityType.directory
            ? 0
            : File(file.path).lengthSync());
    }
    if (items.items.isEmpty) return;
    final otherSideData = model.remoteController.directoryData();
    final toPath = otherSideData.directory.path;
    if (toPath.isEmpty) return;
    final ok = await _waldConfirmSend(items.items.length, toPath);
    if (ok != true) return;
    model.localController.sendFiles(items, otherSideData);
  }

  Future<bool?> _waldConfirmSend(int count, String toPath) {
    return _ffi.dialogManager.show<bool>(
        (setState, Function(bool v) close, context) {
      cancel() => close(false);
      submit() => close(true);
      return CustomAlertDialog(
        contentBoxConstraints: BoxConstraints(minWidth: 400, maxWidth: 400),
        content: waldDialogHeader(
            badge: waldDialogBadge(waldIcon(Icons.upload_rounded))
                .marginOnly(right: 14),
            // 번역 함수가 '{N}' 의 N 을 번역문의 '{}' 에 넣는다(src/lang.rs extract_placeholder).
            title: translate('Send {$count} item(s) to remote?'),
            text: toPath),
        actions: [
          dialogButton(
            'Cancel',
            icon: Icon(waldIcon(Icons.close_rounded)),
            onPressed: cancel,
            isOutline: true,
          ),
          dialogButton('Send', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: cancel,
      );
    }, useAnimation: false);
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final FFI _ffi;
  final Rx<MouseFocusScope> _mouseFocusScope;

  FileManagerView(this.controller, this._ffi, this._mouseFocusScope,
      {super.key});

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _locationStatus = LocationStatus.bread.obs;
  final _locationNode = FocusNode();
  final _locationBarKey = GlobalKey();
  final _searchText = "".obs;
  final _breadCrumbScroller = ScrollController();
  final _keyboardNode = FocusNode();
  final _listSearchBuffer = TimeoutStringBuffer();
  final _nameColWidth = 0.0.obs;
  final _modifiedColWidth = 0.0.obs;
  final _sizeColWidth = 0.0.obs;
  final _fileListScrollController = ScrollController();
  final _globalHeaderKey = GlobalKey();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  var _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  double? _windowWidthPrev;
  double _fileTransferMinimumWidth = 0.0;

  FileController get controller => widget.controller;
  bool get isLocal => widget.controller.isLocal;
  FFI get _ffi => widget._ffi;
  SelectedItems get selectedItems => controller.selectedItems;

  @override
  void initState() {
    super.initState();
    // register location listener
    _locationNode.addListener(onLocationFocusChanged);
    controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  void dispose() {
    _locationNode.removeListener(onLocationFocusChanged);
    _locationNode.dispose();
    _keyboardNode.dispose();
    _breadCrumbScroller.dispose();
    _fileListScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _handleColumnPorportions();
    return Container(
      margin: const EdgeInsets.all(16.0),
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          headTools(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: MouseRegion(
                  onEnter: (evt) {
                    widget._mouseFocusScope.value = isLocal
                        ? MouseFocusScope.local
                        : MouseFocusScope.remote;
                    _keyboardNode.requestFocus();
                  },
                  onExit: (evt) =>
                      widget._mouseFocusScope.value = MouseFocusScope.none,
                  child: _buildFileList(context, _fileListScrollController),
                ))
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Waldlust(DSK-07, 부록 A-36): 이름 칸을 가장 넓게. 수정일·크기 칸은 글자가 들어가는 너비로 두고 남는 너비를
  // 이름 칸에 준다. 창 너비가 바뀌면 목록 너비가 바뀐 만큼 이름 칸만 늘고 준다(전에는 세 칸 모두 창 너비 × 0.115 에서
  // 시작해 창 너비 비율로 늘고 줄었다).
  void _handleColumnPorportions() {
    final windowWidthNow = MediaQuery.of(context).size.width;
    final listShare = _kWaldFilePanelFlex /
        ((isWeb ? 1 : 2) * _kWaldFilePanelFlex + _kWaldStatusFlex);
    if (_windowWidthPrev == null) {
      _windowWidthPrev = windowWidthNow;
      final defaultColumnWidth = windowWidthNow * 0.115;
      _fileTransferMinimumWidth = defaultColumnWidth / 3;
      // 목록 너비 = 패널 너비 − 바깥 여백 16·안쪽 여백 8(양쪽) − 카드 테두리 1(양쪽) − 칸 사이 2 × 2.
      final listWidth = windowWidthNow * listShare - 54;
      _modifiedColWidth.value = _kWaldModifiedColWidth;
      _sizeColWidth.value = _kWaldSizeColWidth;
      _nameColWidth.value = max(_fileTransferMinimumWidth,
          listWidth - _kWaldModifiedColWidth - _kWaldSizeColWidth);
    }

    if (_windowWidthPrev != windowWidthNow) {
      final delta = (windowWidthNow - _windowWidthPrev!) * listShare;
      _windowWidthPrev = windowWidthNow;
      _nameColWidth.value =
          max(_fileTransferMinimumWidth, _nameColWidth.value + delta);
    }
  }

  void onLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNode.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatus.value != LocationStatus.fileSearchBar) {
        _locationStatus.value = LocationStatus.bread;
      }
    }
  }

  Widget headTools() {
    var uploadButtonTapPosition = RelativeRect.fill;
    RxBool isUploadFolder =
        (bind.mainGetLocalOption(key: 'upload-folder-button') == 'Y').obs;
    return Container(
      child: Column(
        children: [
          // symbols
          PreferredSize(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Waldlust(DSK-07, 부록 A-36): 배지 50 → 40, 제목 16·굵게.
                      Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                            color: MyTheme.accent,
                          ),
                          padding: EdgeInsets.all(7.0),
                          child: FutureBuilder<String>(
                              future: bind.sessionGetPlatform(
                                  sessionId: _ffi.sessionId,
                                  isRemote: !isLocal),
                              builder: (context, snapshot) {
                                if (snapshot.hasData &&
                                    snapshot.data!.isNotEmpty) {
                                  return getPlatformImage('${snapshot.data}');
                                } else {
                                  return CircularProgressIndicator(
                                    color: Theme.of(context)
                                        .tabBarTheme
                                        .labelColor,
                                  );
                                }
                              })),
                      Text(
                              isLocal
                                  ? translate("Local Computer")
                                  : translate("Remote Computer"),
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: WaldPalette.neutral900))
                          .marginOnly(left: 10.0)
                    ],
                  ),
                  preferredSize: Size(double.infinity, 70))
              .paddingOnly(bottom: 15),
          // buttons
          Row(
            children: [
              Row(
                children: [
                  MenuButton(
                    tooltip: translate('Back'),
                    padding: EdgeInsets.only(
                      right: 3,
                    ),
                    child: RotatedBox(
                      quarterTurns: 2,
                      child: waldSvg("assets/arrow.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goBack();
                    },
                  ),
                  MenuButton(
                    tooltip: translate('Parent directory'),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: waldSvg("assets/arrow.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                    ),
                    color: Theme.of(context).cardColor,
                    hoverColor: Theme.of(context).hoverColor,
                    onPressed: () {
                      selectedItems.clear();
                      controller.goToParentDirectory();
                    },
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.all(
                        Radius.circular(8.0),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 2.5),
                      child: GestureDetector(
                        onTap: () {
                          _locationStatus.value =
                              _locationStatus.value == LocationStatus.bread
                                  ? LocationStatus.pathLocation
                                  : LocationStatus.bread;
                          Future.delayed(Duration.zero, () {
                            if (_locationStatus.value ==
                                LocationStatus.pathLocation) {
                              _locationNode.requestFocus();
                            }
                          });
                        },
                        child: Obx(
                          () => Container(
                            child: Row(
                              children: [
                                Expanded(
                                    child: _locationStatus.value ==
                                            LocationStatus.bread
                                        ? buildBread()
                                        : buildPathLocation()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Obx(() {
                switch (_locationStatus.value) {
                  case LocationStatus.bread:
                    return MenuButton(
                      tooltip: translate('Search'),
                      onPressed: () {
                        _locationStatus.value = LocationStatus.fileSearchBar;
                        Future.delayed(
                            Duration.zero, () => _locationNode.requestFocus());
                      },
                      child: waldSvg("assets/search.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.pathLocation:
                    return MenuButton(
                      onPressed: null,
                      child: waldSvg("assets/close.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                      color: Theme.of(context).disabledColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                  case LocationStatus.fileSearchBar:
                    return MenuButton(
                      tooltip: translate('Clear'),
                      onPressed: () {
                        onSearchText("", isLocal);
                        _locationStatus.value = LocationStatus.bread;
                      },
                      child: waldSvg("assets/close.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    );
                }
              }),
              MenuButton(
                tooltip: translate('Refresh File'),
                padding: EdgeInsets.only(
                  left: 3,
                ),
                onPressed: () {
                  controller.refresh();
                },
                child: waldSvg("assets/refresh.svg",
                    color: Theme.of(context).tabBarTheme.labelColor),
                color: Theme.of(context).cardColor,
                hoverColor: Theme.of(context).hoverColor,
              ),
            ],
          ),
          Row(
            textDirection: isLocal ? TextDirection.ltr : TextDirection.rtl,
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment:
                      isLocal ? MainAxisAlignment.start : MainAxisAlignment.end,
                  children: [
                    MenuButton(
                      tooltip: translate('Home'),
                      padding: EdgeInsets.only(
                        right: 3,
                      ),
                      onPressed: () {
                        controller.goToHomeDirectory();
                      },
                      child: waldSvg("assets/home.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    ),
                    MenuButton(
                      tooltip: translate('Create Folder'),
                      onPressed: () {
                        final name = TextEditingController();
                        String? errorText;
                        _ffi.dialogManager.show((setState, close, context) {
                          name.addListener(() {
                            if (errorText != null) {
                              setState(() {
                                errorText = null;
                              });
                            }
                          });
                          submit() {
                            if (name.value.text.isNotEmpty) {
                              if (!PathUtil.validName(name.value.text,
                                  controller.options.value.isWindows)) {
                                setState(() {
                                  errorText = translate("Invalid folder name");
                                });
                                return;
                              }
                              controller.createDir(PathUtil.join(
                                controller.directory.value.path,
                                name.value.text,
                                controller.options.value.isWindows,
                              ));
                              close();
                            }
                          }

                          cancel() => close(false);
                          return CustomAlertDialog(
                            title: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                waldSvg("assets/folder_new.svg",
                                    color: MyTheme.accent),
                                Text(
                                  translate("Create Folder"),
                                ).paddingOnly(
                                  left: 10,
                                ),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextFormField(
                                  decoration: InputDecoration(
                                    labelText: translate(
                                      "Please enter the folder name",
                                    ),
                                    errorText: errorText,
                                  ),
                                  controller: name,
                                  autofocus: true,
                                ).workaroundFreezeLinuxMint(),
                              ],
                            ),
                            actions: [
                              dialogButton(
                                "Cancel",
                                icon: Icon(waldIcon(Icons.close_rounded)),
                                onPressed: cancel,
                                isOutline: true,
                              ),
                              dialogButton(
                                "Ok",
                                icon: Icon(waldIcon(Icons.done_rounded)),
                                onPressed: submit,
                              ),
                            ],
                            onSubmit: submit,
                            onCancel: cancel,
                          );
                        });
                      },
                      child: waldSvg("assets/folder_new.svg",
                          color: Theme.of(context).tabBarTheme.labelColor),
                      color: Theme.of(context).cardColor,
                      hoverColor: Theme.of(context).hoverColor,
                    ),
                    Obx(() => MenuButton(
                          tooltip: translate('Delete'),
                          onPressed: SelectedItems.valid(selectedItems.items)
                              ? () async {
                                  await (controller
                                      .removeAction(selectedItems));
                                  selectedItems.clear();
                                }
                              : null,
                          child: waldSvg("assets/trash.svg",
                              color: Theme.of(context).tabBarTheme.labelColor),
                          color: Theme.of(context).cardColor,
                          hoverColor: Theme.of(context).hoverColor,
                        )),
                    menu(isLocal: isLocal),
                  ],
                ),
              ),
              if (isWeb)
                Obx(() => ElevatedButton.icon(
                      style: ButtonStyle(
                        padding: MaterialStateProperty.all<EdgeInsetsGeometry>(
                            isLocal
                                ? EdgeInsets.only(left: 10)
                                : EdgeInsets.only(right: 10)),
                        backgroundColor: MaterialStateProperty.all(
                          selectedItems.items.isEmpty
                              ? MyTheme.accent80
                              : MyTheme.accent,
                        ),
                      ),
                      onPressed: () =>
                          {webselectFiles(is_folder: isUploadFolder.value)},
                      label: InkWell(
                        hoverColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        focusColor: Colors.transparent,
                        onTapDown: (e) {
                          final x = e.globalPosition.dx;
                          final y = e.globalPosition.dy;
                          uploadButtonTapPosition =
                              RelativeRect.fromLTRB(x, y, x, y);
                        },
                        onTap: () async {
                          final value = await showMenu<bool>(
                              context: context,
                              position: uploadButtonTapPosition,
                              items: [
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Text(translate('Upload files')),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Text(translate('Upload folder')),
                                ),
                              ]);
                          if (value != null) {
                            isUploadFolder.value = value;
                            bind.mainSetLocalOption(
                                key: 'upload-folder-button',
                                value: value ? 'Y' : '');
                            webselectFiles(is_folder: value);
                          }
                        },
                        child: Icon(waldIcon(Icons.arrow_drop_down)),
                      ),
                      icon: Text(
                        translate(isUploadFolder.isTrue
                            ? 'Upload folder'
                            : 'Upload files'),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.white,
                        ),
                      ).marginOnly(left: 8),
                    )).marginOnly(left: 16),
              // Waldlust(DSK-07): 테마 주요 버튼(색·비활성은 테마). 아이콘은 방향 화살표(→·←) 대신
              // 전송 목록과 같은 업로드(보내기)·다운로드(받기) 아이콘을 라벨 앞에 둔다.
              // 두 버튼 너비는 같게(최소 120, 'Receive'·'보내기'가 들어가는 너비).
              Obx(() => ElevatedButton.icon(
                    style: const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll(
                            Size(120, WaldSize.buttonHeight))),
                    onPressed: SelectedItems.valid(selectedItems.items)
                        ? () {
                            final otherSideData =
                                controller.getOtherSideDirectoryData();
                            controller.sendFiles(selectedItems, otherSideData);
                            selectedItems.clear();
                          }
                        : null,
                    icon: !isLocal && isWeb
                        ? Offstage()
                        : Icon(
                            waldIcon(isLocal ? Icons.upload : Icons.download)),
                    label: Text(
                      translate(isLocal
                          ? 'Send'
                          : isWeb
                              ? 'Download'
                              : 'Receive'),
                      strutStyle: waldButtonStrut(),
                    ),
                  )),
            ],
          ).marginOnly(top: 8.0)
        ],
      ),
    );
  }

  Widget menu({bool isLocal = false}) {
    var menuPos = RelativeRect.fill;

    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return controller.options.value.showHidden;
        },
        setter: (bool v) async {
          controller.toggleShowHidden();
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
          childBuilder: (style) => Text(translate("Select All"), style: style),
          proc: () => setState(() =>
              selectedItems.selectAll(controller.directory.value.entries)),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true),
      MenuEntryButton(
          childBuilder: (style) =>
              Text(translate("Unselect All"), style: style),
          proc: () => selectedItems.clear(),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true)
    ];

    return Listener(
      onPointerDown: (e) {
        final x = e.position.dx;
        final y = e.position.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      child: MenuButton(
        tooltip: translate('More'),
        onPressed: () => mod_menu.showMenu(
          context: context,
          position: menuPos,
          items: items
              .map(
                (e) => e.build(
                  context,
                  MenuConfig(
                      commonColor: CustomPopupMenuTheme.commonColor,
                      height: CustomPopupMenuTheme.height,
                      dividerHeight: CustomPopupMenuTheme.dividerHeight),
                ),
              )
              .expand((i) => i)
              .toList(),
          elevation: 8,
        ),
        child: waldSvg("assets/dots.svg",
            color: Theme.of(context).tabBarTheme.labelColor),
        color: Theme.of(context).cardColor,
        hoverColor: Theme.of(context).hoverColor,
      ),
    );
  }

  Widget _buildFileList(
      BuildContext context, ScrollController scrollController) {
    final fd = controller.directory.value;
    final entries = fd.entries;
    Rx<Entry?> rightClickEntry = Rx(null);

    return ListSearchActionListener(
      node: _keyboardNode,
      buffer: _listSearchBuffer,
      onNext: (buffer) {
        debugPrint("searching next for $buffer");
        assert(buffer.length == 1);
        assert(selectedItems.items.length <= 1);
        var skipCount = 0;
        if (selectedItems.items.isNotEmpty) {
          final index = entries.indexOf(selectedItems.items.first);
          if (index < 0) {
            return;
          }
          skipCount = index + 1;
        }
        var searchResult = entries
            .skip(skipCount)
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        if (searchResult.isEmpty) {
          // cannot find next, lets restart search from head
          debugPrint("restart search from head");
          searchResult = entries.where(
              (element) => element.name.toLowerCase().startsWith(buffer));
        }
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            kDesktopFileTransferRowHeight);
      },
      onSearch: (buffer) {
        debugPrint("searching for $buffer");
        final selectedEntries = selectedItems;
        final searchResult = entries
            .where((element) => element.name.toLowerCase().startsWith(buffer));
        selectedEntries.clear();
        if (searchResult.isEmpty) {
          selectedItems.clear();
          return;
        }
        _jumpToEntry(isLocal, searchResult.first, scrollController,
            kDesktopFileTransferRowHeight);
      },
      child: Obx(() {
        final entries = controller.directory.value.entries;
        final filteredEntries = _searchText.isNotEmpty
            ? entries.where((element) {
                return element.name.contains(_searchText.value);
              }).toList(growable: false)
            : entries;
        final rows = filteredEntries.map((entry) {
          final sizeStr =
              entry.isFile ? readableFileSize(entry.size.toDouble()) : "";
          final lastModifiedStr = entry.isDrive
              ? " "
              : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
          var secondaryPosition = RelativeRect.fromLTRB(0, 0, 0, 0);
          onTap() {
            final items = selectedItems;
            // handle double click
            if (_checkDoubleClick(entry)) {
              // Waldlust(DSK-08): 내 PC 파일은 OS 기본 앱으로 연다(실행 파일은 폴더에서 보기 — Q-16 (c)).
              // 원격 파일은 아무것도 하지 않는다. 업스트림은 파일에도 openDirectory 를 불러 조용히 실패했다.
              if (entry.isFile) {
                if (isLocal) waldOpenLocalFile(entry.path);
                return;
              }
              controller.openDirectory(entry.path);
              items.clear();
              return;
            }
            _onSelectedChanged(items, filteredEntries, entry, isLocal);
          }

          onSecondaryTap() {
            final items = [
              if (!entry.isDrive &&
                  versionCmp(_ffi.ffiModel.pi.version, "1.3.0") >= 0)
                mod_menu.PopupMenuItem(
                  child: Text(translate("Rename")),
                  height: CustomPopupMenuTheme.height,
                  onTap: () {
                    controller.renameAction(entry, isLocal);
                  },
                ),
              // Waldlust(DSK-08): 내 PC 항목은 든 폴더를 열고 그 항목을 선택한다(Finder·탐색기).
              if (isLocal && !entry.isDrive)
                mod_menu.PopupMenuItem(
                  child: Text(translate(Platform.isMacOS
                      ? 'Show in Finder'
                      : Platform.isWindows
                          ? 'Show in Explorer'
                          : 'Open folder')),
                  height: CustomPopupMenuTheme.height,
                  onTap: () => waldRevealLocalPath(entry.path),
                ),
            ];
            if (items.isNotEmpty) {
              rightClickEntry.value = entry;
              final future = mod_menu.showMenu(
                context: context,
                position: secondaryPosition,
                items: items,
              );
              future.then((value) {
                rightClickEntry.value = null;
              });
              future.onError((error, stackTrace) {
                rightClickEntry.value = null;
              });
            }
          }

          onSecondaryTapDown(details) {
            secondaryPosition = RelativeRect.fromLTRB(
                details.globalPosition.dx,
                details.globalPosition.dy,
                details.globalPosition.dx,
                details.globalPosition.dy);
          }

          return _WaldHoverRow(
            builder: (hovered) => Obx(() => Container(
                // Waldlust(DSK-07, 부록 A-36): 어드민 표 행 — 흰 바탕 + 아래 n100 구분선(행 사이 1px 틈 없앰),
                // 마우스 올림 n100, 선택 n200 + 진한 글자(부록 A-27 의 n300 은 n100 행 바탕 기준이었다).
                // 우클릭 테두리는 그대로다(고르지 않은 테두리에는 둥글기를 줄 수 없어 그때만 둥글기 5).
                decoration: BoxDecoration(
                  color: selectedItems.items.contains(entry)
                      ? WaldPalette.neutral200
                      : hovered
                          ? WaldPalette.neutral100
                          : WaldPalette.white,
                  borderRadius: rightClickEntry.value == entry
                      ? BorderRadius.all(
                          Radius.circular(5.0),
                        )
                      : null,
                  border: rightClickEntry.value == entry
                      ? Border.all(
                          color: MyTheme.button,
                          width: 1.0,
                        )
                      : const Border(
                          bottom: BorderSide(color: WaldPalette.neutral100)),
                ),
                key: ValueKey(entry.name),
                height: kDesktopFileTransferRowHeight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Expanded(
                      child: InkWell(
                        child: Row(
                          children: [
                            GestureDetector(
                              child: Obx(
                                () => Container(
                                    width: _nameColWidth.value,
                                    child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: entry.name,
                                      child: Row(children: [
                                        // Waldlust(DSK-07, 부록 A-36): 드라이브·폴더·파일 종류 아이콘 —
                                        // 폴더만 주황, 드라이브 n600, 파일 n500.
                                        waldIconBox(
                                            waldFileEntryIcon(entry.name,
                                                isDir: !entry.isFile,
                                                isDrive: entry.isDrive),
                                            color: entry.isDrive
                                                ? WaldPalette.neutral600
                                                : entry.isFile
                                                    ? WaldPalette.neutral500
                                                    : WaldPalette.amber500),
                                        Expanded(
                                            child: Text(entry.name.nonBreaking,
                                                overflow:
                                                    TextOverflow.ellipsis))
                                      ]),
                                    )),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            SizedBox(
                              width: 2.0,
                            ),
                            GestureDetector(
                              child: Obx(
                                () => SizedBox(
                                  width: _modifiedColWidth.value,
                                  child: Tooltip(
                                      waitDuration: Duration(milliseconds: 500),
                                      message: lastModifiedStr,
                                      // Waldlust(DSK-07, 부록 A-36): n400 → n500(선택 n600), 숫자 고정폭.
                                      child: Text(
                                        lastModifiedStr,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selectedItems.items
                                                  .contains(entry)
                                              ? WaldPalette.neutral600
                                              : WaldPalette.neutral500,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ],
                                        ),
                                      )),
                                ),
                              ),
                              onTap: onTap,
                              onSecondaryTap: onSecondaryTap,
                              onSecondaryTapDown: onSecondaryTapDown,
                            ),
                            // Divider from header.
                            SizedBox(
                              width: 2.0,
                            ),
                            Expanded(
                              // width: 100,
                              child: GestureDetector(
                                child: Tooltip(
                                  waitDuration: Duration(milliseconds: 500),
                                  message: sizeStr,
                                  // Waldlust(DSK-07, 부록 A-36): 10 → 12, n400 → n500(선택 n600),
                                  // 오른쪽 정렬·숫자 고정폭.
                                  child: Text(
                                    sizeStr,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            selectedItems.items.contains(entry)
                                                ? WaldPalette.neutral600
                                                : WaldPalette.neutral500,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ]),
                                  ).marginOnly(right: 8),
                                ),
                                onTap: onTap,
                                onSecondaryTap: onSecondaryTap,
                                onSecondaryTapDown: onSecondaryTapDown,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ))),
          );
        }).toList(growable: false);

        // Waldlust(DSK-07, 부록 A-36): 목록을 어드민 표 카드(흰 바탕·n200 테두리·둥글기 12)로 감싼다.
        // 테두리 안쪽 1px 에 둥글게 잘라 머리줄 바탕이 테두리를 덮지 않게 한다.
        return Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(1),
          decoration: waldCardDecoration(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WaldSize.cardRadius - 1),
            child: Column(
              children: [
                // Header
                Row(
                  children: [
                    Expanded(child: _buildFileBrowserHeader(context)),
                  ],
                ),
                // Body
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemExtent: kDesktopFileTransferRowHeight,
                    itemBuilder: (context, index) {
                      return rows[index];
                    },
                    itemCount: rows.length,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  onSearchText(String searchText, bool isLocal) {
    selectedItems.clear();
    _searchText.value = searchText;
  }

  void _jumpToEntry(bool isLocal, Entry entry,
      ScrollController scrollController, double rowHeight) {
    final entries = controller.directory.value.entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = selectedItems;
    final searchResult = entries.where((element) => element == entry);
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
        max(scrollController.position.minScrollExtent,
            entries.indexOf(searchResult.first) * rowHeight),
        scrollController.position.maxScrollExtent);
    scrollController.jumpTo(offset);
    selectedEntries.add(searchResult.first);
    debugPrint("focused on ${searchResult.first.name}");
  }

  /// Waldlust(DSK-07): 내 파일 목록에 끌어 놓은 폴더로 들어간다. 파일이면 든 폴더를
  /// 열고 놓은 파일을 선택한다(부록 A-37). 여러 개면 첫 항목 기준.
  Future<void> waldOpenDropped(DropDoneDetails details) async {
    if (details.files.isEmpty) return;
    final first = details.files.first.path;
    final type = FileSystemEntity.typeSync(first);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      selectedItems.clear();
      await controller.openDirectory(first);
      return;
    }
    final isWindows = controller.options.value.isWindows;
    final dir = PathUtil.dirname(first, isWindows);
    if (!await controller.openDirectory(dir)) return;
    final names = details.files
        .where((f) => PathUtil.dirname(f.path, isWindows) == dir)
        .map((f) => f.name)
        .toSet();
    final dropped = controller.directory.value.entries
        .where((e) => names.contains(e.name))
        .toList();
    selectedItems.clear();
    if (dropped.isEmpty) return;
    // 새 목록이 그려진 뒤에야 스크롤 범위가 맞다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_fileListScrollController.hasClients) return;
      _jumpToEntry(isLocal, dropped.first, _fileListScrollController,
          kDesktopFileTransferRowHeight);
      dropped.skip(1).forEach(selectedItems.add);
      setState(() {});
    });
  }

  void _onSelectedChanged(SelectedItems selectedItems, List<Entry> entries,
      Entry entry, bool isLocal) {
    final isCtrlDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight);
    final isShiftDown = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);
    if (isCtrlDown) {
      if (selectedItems.items.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(e));
    } else {
      selectedItems.clear();
      selectedItems.add(entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  void _onDrag(double dx, RxDouble column1, RxDouble column2) {
    if (column1.value + dx <= _fileTransferMinimumWidth ||
        column2.value - dx <= _fileTransferMinimumWidth) {
      return;
    }
    column1.value += dx;
    column2.value -= dx;
    column1.value = max(_fileTransferMinimumWidth, column1.value);
    column2.value = max(_fileTransferMinimumWidth, column2.value);
  }

  Widget _buildFileBrowserHeader(BuildContext context) {
    final padding = EdgeInsets.all(1.0);
    // Waldlust(DSK-07, 부록 A-36): 어드민 표 머리 — n50 바탕 + 아래 n200 선.
    return Container(
      key: _globalHeaderKey,
      height: kDesktopFileTransferHeaderHeight,
      decoration: const BoxDecoration(
        color: WaldPalette.neutral50,
        border: Border(bottom: BorderSide(color: WaldPalette.neutral200)),
      ),
      child: Row(
        children: [
          Obx(
            () => headerItemFunc(
                _nameColWidth.value, SortBy.name, translate("Name")),
          ),
          DraggableDivider(
            axis: Axis.vertical,
            onPointerMove: (dx) =>
                _onDrag(dx, _nameColWidth, _modifiedColWidth),
            padding: padding,
          ),
          Obx(
            () => headerItemFunc(_modifiedColWidth.value, SortBy.modified,
                translate("Modified")),
          ),
          DraggableDivider(
              axis: Axis.vertical,
              onPointerMove: (dx) =>
                  _onDrag(dx, _modifiedColWidth, _sizeColWidth),
              padding: padding),
          Expanded(
              child: headerItemFunc(
                  _sizeColWidth.value, SortBy.size, translate("Size"),
                  alignEnd: true))
        ],
      ),
    );
  }

  Widget headerItemFunc(double? width, SortBy sortBy, String name,
      {bool alignEnd = false}) {
    // Waldlust(DSK-07, 부록 A-36): 머리 글자 12·w500·n500(본문과 구분), [alignEnd] 는 오른쪽 정렬(크기).
    final headerTextStyle =
        (Theme.of(context).dataTableTheme.headingTextStyle ?? TextStyle())
            .copyWith(
                fontSize: WaldSize.smallFont,
                fontWeight: FontWeight.w500,
                color: WaldPalette.neutral500);
    return ObxValue<Rx<bool?>>(
        (ascending) => InkWell(
              onTap: () {
                if (ascending.value == null) {
                  ascending.value = true;
                } else {
                  ascending.value = !ascending.value!;
                }
                controller.changeSortStyle(sortBy,
                    isLocal: isLocal, ascending: ascending.value!);
              },
              child: SizedBox(
                width: width,
                height: kDesktopFileTransferHeaderHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: headerTextStyle,
                        overflow: TextOverflow.ellipsis,
                        textAlign: alignEnd ? TextAlign.right : null,
                      ).marginOnly(left: 4, right: alignEnd ? 8 : 0),
                    ),
                    ascending.value != null
                        ? Icon(
                            ascending.value!
                                ? waldIcon(Icons.keyboard_arrow_up_rounded)
                                : waldIcon(Icons.keyboard_arrow_down_rounded),
                            size: WaldSize.iconSm,
                            color: WaldPalette.neutral500,
                          )
                        : SizedBox()
                  ],
                ),
              ),
            ), () {
      if (controller.sortBy.value == sortBy) {
        return controller.sortAscending.obs;
      } else {
        return Rx<bool?>(null);
      }
    }());
  }

  Widget buildBread() {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, controller.options.value.isWindows);
      }
      controller.openDirectory(path);
    });

    return items.isEmpty
        ? Offstage()
        : Row(
            key: _locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Expanded(
                  child: Listener(
                    // handle mouse wheel
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        final sc = _breadCrumbScroller;
                        final scale = isWindows ? 2 : 4;
                        sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                      }
                    },
                    child: BreadCrumb(
                      items: items,
                      // Waldlust(DSK-07, 부록 A-36): 구분 화살표 14·n400.
                      divider: Icon(
                          waldIcon(Icons.keyboard_arrow_right_rounded),
                          size: 14,
                          color: WaldPalette.neutral400),
                      overflow: ScrollableOverflow(
                        controller: _breadCrumbScroller,
                      ),
                    ),
                  ),
                ),
                ActionIcon(
                  message: "",
                  icon: waldIcon(Icons.keyboard_arrow_down_rounded),
                  onTap: () async {
                    final renderBox = _locationBarKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    _locationBarKey.currentContext?.size;

                    final size = renderBox.size;
                    final offset = renderBox.localToGlobal(Offset.zero);

                    final x = offset.dx;
                    final y = offset.dy + size.height + 1;

                    final isPeerWindows = controller.options.value.isWindows;
                    final List<MenuEntryBase> menuItems = [
                      MenuEntryButton(
                          childBuilder: (TextStyle? style) => isPeerWindows
                              ? buildWindowsThisPC(context, style)
                              : Text(
                                  '/',
                                  style: style,
                                ),
                          proc: () {
                            controller.openDirectory('/');
                          },
                          dismissOnClicked: true),
                      MenuEntryDivider()
                    ];
                    if (isPeerWindows) {
                      var loadingTag = "";
                      if (!isLocal) {
                        loadingTag = _ffi.dialogManager.showLoading("Waiting");
                      }
                      try {
                        final showHidden = controller.options.value.showHidden;
                        final fd = await controller.fileFetcher
                            .fetchDirectory("/", isLocal, showHidden);
                        for (var entry in fd.entries) {
                          menuItems.add(MenuEntryButton(
                              childBuilder: (TextStyle? style) =>
                                  Row(children: [
                                    // Waldlust(DSK-07, 부록 A-36): 목록과 같은 드라이브 아이콘.
                                    Icon(waldFileEntryIcon('', isDrive: true),
                                        size: WaldSize.icon,
                                        color: WaldPalette.neutral600),
                                    SizedBox(width: 10),
                                    Text(
                                      entry.name,
                                      style: style,
                                    )
                                  ]),
                              proc: () {
                                controller.openDirectory('${entry.name}\\');
                              },
                              dismissOnClicked: true));
                        }
                        menuItems.add(MenuEntryDivider());
                      } catch (e) {
                        debugPrint("buildBread fetchDirectory err=$e");
                      } finally {
                        if (!isLocal) {
                          _ffi.dialogManager.dismissByTag(loadingTag);
                        }
                      }
                    }
                    mod_menu.showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(x, y, x, y),
                        elevation: 4,
                        items: menuItems
                            .map((e) => e.build(
                                context,
                                MenuConfig(
                                    commonColor:
                                        CustomPopupMenuTheme.commonColor,
                                    height: CustomPopupMenuTheme.height,
                                    dividerHeight:
                                        CustomPopupMenuTheme.dividerHeight,
                                    boxWidth: size.width)))
                            .expand((i) => i)
                            .toList());
                  },
                  iconSize: 20,
                )
              ]);
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
      bool isLocal, void Function(List<String>) onPressed) {
    final path = controller.directory.value.path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = controller.options.value.isWindows;
    if (isWindows && path == '/') {
      breadCrumbList.add(BreadCrumbItem(
          content: TextButton(
                  child: buildWindowsThisPC(context, _kWaldPathCurrentStyle),
                  style: ButtonStyle(
                      minimumSize: MaterialStateProperty.all(Size(0, 0))),
                  onPressed: () => onPressed(['/']))
              .marginSymmetric(horizontal: 4)));
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(
        list.asMap().entries.map(
              (e) => BreadCrumbItem(
                content: TextButton(
                  // Waldlust(DSK-07, 부록 A-36): 현재 폴더(마지막 조각)만 진하게, 앞 조각은 회색. 더 많이
                  // 보이게 글자 14 → 12, 조각 좌우 여백 8 → 4·바깥 4 → 2.
                  child: Text(e.value,
                      style: e.key == list.length - 1
                          ? _kWaldPathCurrentStyle
                          : _kWaldPathStyle),
                  style: ButtonStyle(
                    minimumSize: MaterialStateProperty.all(
                      Size(0, 0),
                    ),
                    padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 4, vertical: 8)),
                  ),
                  onPressed: () => onPressed(
                    list.sublist(0, e.key + 1),
                  ),
                ).marginSymmetric(horizontal: 2),
              ),
            ),
      );
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
            _breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget buildPathLocation() {
    final text = _locationStatus.value == LocationStatus.pathLocation
        ? controller.directory.value.path
        : _searchText.value;
    final textController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    return Row(
      children: [
        waldSvg(
            _locationStatus.value == LocationStatus.pathLocation
                ? "assets/folder.svg"
                : "assets/search.svg",
            color: Theme.of(context).tabBarTheme.labelColor),
        Expanded(
          child: TextField(
            focusNode: _locationNode,
            // Waldlust(DSK-07, 부록 A-36): 경로 막대와 같은 12.
            style: const TextStyle(fontSize: WaldSize.smallFont),
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              prefix: Padding(
                padding: EdgeInsets.only(left: 4.0),
              ),
            ),
            controller: textController,
            onSubmitted: (path) {
              controller.openDirectory(path);
            },
            onChanged: _locationStatus.value == LocationStatus.fileSearchBar
                ? (searchText) => onSearchText(searchText, isLocal)
                : null,
          ).workaroundFreezeLinuxMint(),
        )
      ],
    );
  }

  // openDirectory(String path, {bool isLocal = false}) {
  //   model.openDirectory(path, isLocal: isLocal);
  // }
}

Widget buildWindowsThisPC(BuildContext context, [TextStyle? textStyle]) {
  final color = Theme.of(context).iconTheme.color?.withOpacity(0.7);
  return Row(children: [
    Icon(waldIcon(Icons.computer), size: 20, color: color),
    SizedBox(width: 10),
    Text(translate('This PC'), style: textStyle)
  ]);
}

// Waldlust(DSK-07, 부록 A-36): 경로 막대 글자 — 앞 조각 n500, 현재 폴더 굵게 n900.
const _kWaldPathStyle =
    TextStyle(fontSize: WaldSize.smallFont, color: WaldPalette.neutral500);
const _kWaldPathCurrentStyle = TextStyle(
    fontSize: WaldSize.smallFont,
    fontWeight: FontWeight.w600,
    color: WaldPalette.neutral900);

/// Waldlust(DSK-07, 부록 A-36): 파일 목록 행의 마우스 올림 표시. 탭·우클릭은 행 안의 GestureDetector 가 그대로 받는다.
class _WaldHoverRow extends StatefulWidget {
  final Widget Function(bool hovered) builder;

  const _WaldHoverRow({Key? key, required this.builder}) : super(key: key);

  @override
  State<_WaldHoverRow> createState() => _WaldHoverRowState();
}

class _WaldHoverRowState extends State<_WaldHoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: widget.builder(_hovered),
      );
}
