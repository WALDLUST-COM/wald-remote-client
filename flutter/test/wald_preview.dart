// Waldlust(DSK-07): 디자인 미리보기. 원격 툴바·파일 전송 창을 연결 없이 '연결된 상태'로 띄운다.
//
// flutter run -d macos --release -t test/wald_preview.dart
//
// - 연결 관리 창은 test/cm_demo.dart 를 쓴다.
// - 핀·닫기·전체화면·채팅 버튼은 누르지 않는다(공용 설정에 쓰거나 세션이 필요하다).
// - 라이트/다크 버튼은 이 창만 바꾼다(Get.changeThemeMode). 공용 설정(theme)은 건드리지 않는다.
//   MyTheme.currentThemeMode() 로 색을 고르는 곳은 앱 설정·시스템 모드를 따르므로,
//   다크를 정확히 보려면 시스템 화면 모드도 다크로 둔다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

const _kToolbarPeerId = 'wald-preview';
const _kAndroidToolbarPeerId = 'wald-preview-android';
const _kFilePeerId = 'wald-preview-ft';

void main() async {
  isTest = true;
  waldFileManagerPreview = true;
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await initEnv(kAppTypeMain);

  final controller = DesktopTabController(tabType: DesktopTabType.cm);
  controller.add(TabInfo(
      key: 'toolbar',
      label: '원격 툴바',
      selectedIcon: Icons.desktop_windows_sharp,
      unselectedIcon: Icons.desktop_windows_outlined,
      closable: false,
      page: const _ToolbarPreview()));
  controller.add(TabInfo(
      key: 'toolbar-android',
      label: '원격 툴바(Android)',
      selectedIcon: Icons.phone_android,
      unselectedIcon: Icons.phone_android_outlined,
      closable: false,
      page: const _ToolbarPreview(android: true)));
  controller.add(TabInfo(
      key: 'files',
      label: '파일 전송',
      selectedIcon: Icons.file_copy_sharp,
      unselectedIcon: Icons.file_copy_outlined,
      closable: false,
      page: const _FileTransferPreview()));
  controller.add(TabInfo(
      key: 'gallery',
      label: '버튼·입력',
      selectedIcon: Icons.widgets,
      unselectedIcon: Icons.widgets_outlined,
      closable: false,
      page: const _GalleryPreview()));
  controller.add(TabInfo(
      key: 'dialogs',
      label: '대화상자',
      selectedIcon: Icons.chat_bubble,
      unselectedIcon: Icons.chat_bubble_outline,
      closable: false,
      page: const _DialogPreview()));
  // WALD_PREVIEW_TAB=dialogs 처럼 처음 열 탭을 고른다(화면 캡처용).
  final first = Platform.environment['WALD_PREVIEW_TAB'];
  final firstIndex =
      controller.state.value.tabs.indexWhere((t) => t.key == first);
  controller.jumpTo(firstIndex < 0 ? 0 : firstIndex);

  runApp(GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: MyTheme.lightTheme,
      darkTheme: MyTheme.darkTheme,
      themeMode: MyTheme.currentThemeMode(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedLocales,
      home: Scaffold(
        body: DesktopTab(
          controller: controller,
          showMaximize: false,
          selectedBorderColor: MyTheme.accent,
          tail: const _ThemeToggle(),
        ),
      )));

  WindowOptions windowOptions =
      getHiddenTitleBarWindowOptions(size: const Size(1280, 860));
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.setSize(const Size(1280, 860));
    await windowManager.center();
    await windowManager.focus();
  });
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextButton(
      onPressed: () =>
          Get.changeThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
      child: Text(dark ? '라이트로' : '다크로'),
    ).paddingSymmetric(horizontal: 8);
  }
}

/// 연결된 Windows 기기(디스플레이 2개, 권한 모두 허용)를 가정한 원격 툴바.
/// [android] 면 Android 기기(화면 1개)를 가정하고 모바일 제어 막대를 함께 띄운다
/// (막대 버튼은 가짜 세션으로 보내므로 눌러도 아무 일도 없다).
class _ToolbarPreview extends StatefulWidget {
  const _ToolbarPreview({this.android = false});

  final bool android;

  @override
  State<_ToolbarPreview> createState() => _ToolbarPreviewState();
}

class _ToolbarPreviewState extends State<_ToolbarPreview>
    with AutomaticKeepAliveClientMixin {
  final _ffi = FFI(null);
  final _toolbarState = ToolbarState();

  @override
  bool get wantKeepAlive => true;

  String get _peerId =>
      widget.android ? _kAndroidToolbarPeerId : _kToolbarPeerId;

  @override
  void initState() {
    super.initState();
    _ffi.id = _peerId;
    initSharedStates(_peerId);
    ConnectionTypeState.init(_peerId);
    final pi = _ffi.ffiModel.pi;
    pi.platform = widget.android ? kPeerPlatformAndroid : kPeerPlatformWindows;
    pi.version = '1.4.8';
    pi.username = 'wald';
    pi.hostname = widget.android ? 'PREVIEW-PHONE' : 'PREVIEW-PC';
    // 모니터 선택 메뉴(부록 A-70)에 해상도·주 모니터 줄이 보이도록 실제 PC 같은 값.
    pi.displays.value = [
      Display()
        ..width = 2560
        ..height = 1440,
      if (!widget.android)
        Display()
          ..x = 2560
          ..width = 1920
          ..height = 1080,
    ];
    pi.displaysCount.value = widget.android ? 1 : 2;
    _ffi.ffiModel.setPermissions({
      'keyboard': true,
      'clipboard': true,
      'audio': true,
      'file': true,
      'restart': true,
      'recording': true,
      'block_input': true,
    });
    pi.isSet.value = true;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _ffi.ffiModel),
        ChangeNotifierProvider.value(value: _ffi.imageModel),
        ChangeNotifierProvider.value(value: _ffi.cursorModel),
        ChangeNotifierProvider.value(value: _ffi.canvasModel),
        ChangeNotifierProvider.value(value: _ffi.recordingModel),
      ],
      child: Stack(children: [
        Container(color: kColorCanvas),
        // remote_page.dart 와 같은 방식으로 모바일 제어 막대를 얹는다.
        if (widget.android)
          Obx(() => Offstage(
                offstage:
                    _ffi.dialogManager.mobileActionsOverlayVisible.isFalse,
                child: Overlay(initialEntries: [
                  makeMobileActionsOverlayEntry(
                      () => _ffi.dialogManager
                          .setMobileActionsOverlayVisible(false),
                      ffi: _ffi)
                ]),
              )),
        Overlay(initialEntries: [
          OverlayEntry(
              builder: (_) => RemoteToolbar(
                    id: _peerId,
                    ffi: _ffi,
                    state: _toolbarState,
                    onEnterOrLeaveImageSetter: (_, __) {},
                    onEnterOrLeaveImageCleaner: (_) {},
                    setRemoteState: (_) {},
                  ))
        ]),
      ]),
    );
  }
}

/// 로컬(macOS)·원격(Windows) 목록과 전송 작업 네 상태를 채운 파일 전송 창.
class _FileTransferPreview extends StatefulWidget {
  const _FileTransferPreview();

  @override
  State<_FileTransferPreview> createState() => _FileTransferPreviewState();
}

class _FileTransferPreviewState extends State<_FileTransferPreview> {
  late final FileManagerPage _page =
      FileManagerPage(id: _kFilePeerId, password: null, isSharedPassword: null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fill());
  }

  void _fill() {
    final model = _page.ffi.fileModel;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Entry entry(String name, int type, int size, int ago) => Entry()
      ..name = name
      ..entryType = type
      ..size = size
      ..modifiedTime = now - ago;

    final local = model.localController;
    local.options.value
      ..home = '/Users/wald'
      ..isWindows = false;
    local.directory.value = FileDirectory()
      ..path = '/Users/wald/Documents'
      ..entries = [
        entry('매장 자료', 1, 0, 3600),
        entry('Invoices', 1, 0, 86400),
        entry('메뉴판_2026.pdf', 4, 2345678, 600),
        entry('report.xlsx', 4, 345678, 7200),
        entry('사진.png', 4, 12345678, 172800),
        // 부록 A-36: 파일 종류 아이콘 견본.
        entry('매장 영상.mp4', 4, 104857600, 259200),
        entry('안내 음성.m4a', 4, 3145728, 345600),
        entry('백업_1015.zip', 4, 52428800, 90000),
        entry('notes.txt', 4, 1234, 1200),
        entry('config.json', 4, 856, 4000),
        entry('설치.exe', 4, 1048576, 60),
        entry('README', 4, 512, 600000),
      ]
      ..format(false);

    final remote = model.remoteController;
    remote.options.value
      ..home = 'C:\\Users\\POS'
      ..isWindows = true;
    remote.directory.value = FileDirectory()
      ..path = 'C:\\Users\\POS\\Desktop'
      ..entries = [
        // 부록 A-36: 드라이브 아이콘 견본(실제로는 '내 PC' 에만 나온다).
        entry('C:', 3, 0, 0),
        entry('D:', 3, 0, 0),
        entry('주문 백업', 1, 0, 1800),
        entry('Logs', 1, 0, 5400),
        entry('설정.ini', 4, 2048, 300),
        entry('sales_0930.csv', 4, 98765, 9000),
        entry('영수증.jpg', 4, 245760, 7000),
        entry('POS_Setup.msi', 4, 73400320, 500000),
        entry('error.log', 4, 40960, 100),
      ]
      ..format(true);

    // 작업 이름은 실제처럼 원본 전체 경로다(목록에는 마지막 이름만 보여야 한다).
    JobProgress job(int id, JobState state, String name, int total, int done,
            {bool toLocal = true, String err = '', String to = ''}) =>
        JobProgress()
          ..id = id
          ..type = JobType.transfer
          ..state = state
          ..fileName = name
          ..jobName = name
          ..to = to
          ..totalSize = total
          ..finishedSize = done
          ..speed = state == JobState.inProgress ? 1536000 : 0
          ..isRemoteToLocal = toLocal
          ..err = err;
    // 받기가 끝난 파일([파일 열기]·[폴더 열기] 확인용)은 임시 폴더에 실제로 만든다.
    final inbox = Directory('${Directory.systemTemp.path}/wald-preview 받은 파일')
      ..createSync(recursive: true);
    final memo = File('${inbox.path}/받은 메모.txt')
      ..writeAsStringSync('Waldlust 미리보기\n');
    final exe = File('${inbox.path}/설치.exe')..writeAsStringSync('');
    model.jobController.jobTable.addAll([
      job(1, JobState.inProgress, r'C:\Users\POS\Desktop\sales_0930.csv',
          98765000, 45000000),
      job(2, JobState.paused, r'C:\Users\POS\Desktop\주문 백업.zip', 52428800,
          10485760),
      job(3, JobState.done, '/Users/wald/Documents/메뉴판_2026.pdf', 2345678,
          2345678,
          toLocal: false),
      job(4, JobState.error, r'C:\Users\POS\Desktop\설정.ini', 2048, 0,
          err: 'Permission denied'),
      job(5, JobState.done, r'C:\Users\POS\Desktop\받은 메모.txt', 4096, 4096,
          to: memo.path),
      job(6, JobState.done, r'C:\Users\POS\Downloads\설치.exe', 1048576, 1048576,
          to: exe.path),
    ]);
  }

  // 덮어쓰기 대화상자(같은 내용 문구·모두 적용 체크박스 포함)를 띄운다.
  void _showOverwriteDialog() => _page.ffi.fileModel.showFileConfirmDialog(
      translate('Overwrite'),
      r'C:\Users\POS\Desktop\sales_0930.csv',
      true,
      true);

  @override
  Widget build(BuildContext context) => Stack(children: [
        _page,
        Positioned(
          left: 16,
          bottom: 16,
          child: OutlinedButton(
              onPressed: _showOverwriteDialog, child: const Text('덮어쓰기 대화상자')),
        ),
      ]);
}

/// 버튼(가운데 기준선 표시)·입력·토글·대화상자·메뉴 견본.
class _GalleryPreview extends StatefulWidget {
  const _GalleryPreview();

  @override
  State<_GalleryPreview> createState() => _GalleryPreviewState();
}

class _GalleryPreviewState extends State<_GalleryPreview> {
  bool _check = true;
  bool _switch = true;
  int _radio = 0;

  // 버튼 세로 가운데에 1px 기준선을 그어 글자가 가운데 있는지 본다.
  Widget _guide(Widget button) => Stack(
        alignment: Alignment.center,
        children: [
          button,
          IgnorePointer(
            child: Container(
                height: 1, width: 140, color: Colors.red.withOpacity(0.6)),
          ),
        ],
      );

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall)
              .paddingOnly(bottom: 8),
          Wrap(spacing: 12, runSpacing: 12, children: children),
        ],
      ).paddingOnly(bottom: 24);

  @override
  Widget build(BuildContext context) {
    void noop() {}
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _section('dialogButton — 한글', [
            _guide(dialogButton('확인', onPressed: noop)),
            _guide(dialogButton('취소', onPressed: noop, isOutline: true)),
            _guide(dialogButton('연결',
                onPressed: noop, icon: const Icon(Icons.done_rounded))),
            _guide(dialogButton('닫기',
                onPressed: noop,
                isOutline: true,
                icon: const Icon(Icons.close_rounded))),
            _guide(dialogButton('비활성', onPressed: null)),
          ]),
          _section('dialogButton — English', [
            _guide(dialogButton('Okay', onPressed: noop)),
            _guide(dialogButton('Dismiss', onPressed: noop, isOutline: true)),
            _guide(dialogButton('Connect now',
                onPressed: noop, icon: const Icon(Icons.done_rounded))),
            _guide(dialogButton('Disabled', onPressed: null)),
          ]),
          _section('Lucide 아이콘 — 16 / 18 / 20', [
            for (final size in [16.0, 18.0, 20.0])
              Wrap(spacing: 10, children: [
                for (final icon in const [
                  LucideIcons.monitor,
                  LucideIcons.keyboard,
                  LucideIcons.messageSquare,
                  LucideIcons.phone,
                  LucideIcons.zap,
                  LucideIcons.pin,
                  LucideIcons.circleDot,
                  LucideIcons.x,
                  LucideIcons.folder,
                  LucideIcons.folderPlus,
                  LucideIcons.trash2,
                  LucideIcons.refreshCw,
                  LucideIcons.house,
                  LucideIcons.settings,
                  LucideIcons.star,
                  LucideIcons.history,
                  LucideIcons.bookUser,
                  LucideIcons.shieldCheck,
                ])
                  Icon(icon, size: size),
              ]),
          ]),
          _section('입력', [
            const SizedBox(
                width: 240,
                child:
                    TextField(decoration: InputDecoration(hintText: '기기 이름'))),
            const SizedBox(
                width: 240,
                child: TextField(
                    decoration: InputDecoration(
                        hintText: '비밀번호', errorText: '비밀번호가 틀렸습니다'))),
            const SizedBox(
                width: 240,
                child: TextField(
                    enabled: false,
                    decoration: InputDecoration(hintText: '비활성'))),
          ]),
          _section('토글', [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                  value: _check,
                  onChanged: (v) => setState(() => _check = v ?? false)),
              const Text('체크박스'),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                  value: _switch,
                  onChanged: (v) => setState(() => _switch = v)),
              const Text('스위치'),
            ]),
            for (final i in [0, 1])
              Row(mainAxisSize: MainAxisSize.min, children: [
                Radio<int>(
                    value: i,
                    groupValue: _radio,
                    onChanged: (v) => setState(() => _radio = v ?? 0)),
                Text('라디오 ${i + 1}'),
              ]),
          ]),
          _section('대화상자·메뉴', [
            dialogButton('대화상자 열기',
                onPressed: () => showDialog(
                    context: context,
                    builder: (context) => CustomAlertDialog(
                          title: const Text('기기 이름 변경'),
                          content: const TextField(
                              decoration: InputDecoration(hintText: '새 이름')),
                          actions: [
                            dialogButton('취소',
                                onPressed: () => Navigator.pop(context),
                                isOutline: true),
                            dialogButton('저장',
                                onPressed: () => Navigator.pop(context)),
                          ],
                        ))),
            PopupMenuButton<int>(
              tooltip: '메뉴',
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text('연결')),
                PopupMenuItem(value: 1, child: Text('파일 전송')),
                PopupMenuItem(value: 2, child: Text('이름 변경')),
              ],
              child: const Icon(Icons.more_vert),
            ),
            const Tooltip(message: '툴팁 예시', child: Text('툴팁(마우스 올리기)')),
          ]),
        ],
      ),
    );
  }
}

/// Waldlust(DSK-07 — 부록 A-74): 대화상자 견본. 실제 대화상자 위젯(CustomAlertDialog)을 누르지 않고
/// 한 화면에 늘어놓는다. 배경은 대화상자 뒤 배경색(MyTheme.dialogScrim)이다. 버튼은 동작하지 않는다.
class _DialogPreview extends StatelessWidget {
  const _DialogPreview();

  Widget _sample(String label, Widget dialog, {double height = 230}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.white)),
          SizedBox(width: 500, height: height, child: dialog),
        ],
      );

  @override
  Widget build(BuildContext context) {
    void noop() {}
    final pw = TextEditingController(text: 'abcd1234');
    return Stack(children: [
      Container(color: Theme.of(context).scaffoldBackgroundColor),
      Container(
        color: MyTheme.dialogScrim,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Wrap(spacing: 16, runSpacing: 12, children: [
            _sample(
                '연결 오류(msgBox error)',
                CustomAlertDialog(
                  content: msgboxContent(
                      'error', 'Connection Error', 'Remote desktop is offline'),
                  actions: [
                    dialogButton('Reconnect',
                        onPressed: noop,
                        isOutline: true,
                        icon: const Icon(Icons.refresh)),
                    dialogButton('OK', onPressed: noop),
                  ],
                )),
            _sample(
                '삭제 확인(deleteConfirmDialog)',
                CustomAlertDialog(
                  content: waldDeleteConfirmContent(
                      translate('wald-delete-peers-{3}-title')),
                  actions: [
                    dialogButton('Cancel', onPressed: noop, isOutline: true),
                    dialogButton('Delete', onPressed: noop, isDanger: true),
                  ],
                )),
            _sample(
                '성공(msgBox success)',
                CustomAlertDialog(
                  content: msgboxContent('success', 'Successful', 'Done'),
                  actions: [dialogButton('OK', onPressed: noop)],
                )),
            _sample(
                '안내(msgBox custom-nocancel-info)',
                CustomAlertDialog(
                  content: msgboxContent('custom-nocancel-info', 'Switch Sides',
                      'Please confirm if you want to share your desktop?'),
                  actions: [
                    dialogButton('Cancel', onPressed: noop, isOutline: true),
                    dialogButton('OK', onPressed: noop),
                  ],
                )),
            _sample(
                '대기(wait-uac)',
                CustomAlertDialog(
                  content:
                      msgboxContent('wait-uac', 'Wait', 'wait_accept_uac_tip'),
                  actions: [dialogButton('OK', onPressed: noop)],
                )),
            _sample(
                '배지 없는 메시지(connecting)',
                CustomAlertDialog(
                  content: msgboxContent('connecting', 'Connecting...',
                      'Connection in progress. Please wait.'),
                  actions: [
                    dialogButton('Cancel', onPressed: noop, isOutline: true)
                  ],
                )),
            _sample(
                '제목 + 입력(비밀번호)',
                CustomAlertDialog(
                  title: Row(children: [
                    Icon(waldIcon(Icons.password_rounded),
                        color: MyTheme.accent),
                    Text(translate('Password Required')).paddingOnly(left: 10),
                  ]),
                  content: TextField(
                    controller: pw,
                    obscureText: true,
                    decoration:
                        InputDecoration(labelText: translate('Password')),
                  ),
                  actions: [
                    dialogButton('Cancel',
                        onPressed: noop,
                        isOutline: true,
                        icon: Icon(waldIcon(Icons.close_rounded))),
                    dialogButton('OK',
                        onPressed: noop,
                        icon: Icon(waldIcon(Icons.done_rounded))),
                  ],
                ),
                height: 250),
            _sample(
                '제목 + 본문(업데이트)',
                CustomAlertDialog(
                  title: Text(translate('wald-update-dialog-title')),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('1.5.11  →  1.5.12',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Text(translate('wald-update-confirm-tip')),
                    ],
                  ),
                  actions: [
                    dialogButton('Cancel', onPressed: noop, isOutline: true),
                    dialogButton('Update', onPressed: noop),
                  ],
                ),
                height: 250),
          ]),
        ]),
      ),
    ]);
  }
}
