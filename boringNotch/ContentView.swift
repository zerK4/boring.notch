//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var devStatusManager = DevStatusManager.shared
    @ObservedObject var clipboardPreviewManager = ClipboardPreviewManager.shared
    @ObservedObject var systemPulseManager = SystemPulseManager.shared
    @ObservedObject var meetingCompanionManager = MeetingCompanionManager.shared
    @ObservedObject var downloadWatcherManager = DownloadWatcherManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.clipboardPreviewEnabled) var clipboardPreviewEnabled
    @Default(.systemPulseEnabled) var systemPulseEnabled
    @Default(.meetingCompanionEnabled) var meetingCompanionEnabled
    @Default(.downloadWatcherEnabled) var downloadWatcherEnabled
    // Shared interactive spring
    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if shouldShowMeetingClosedAlert {
            chinWidth = hasPhysicalNotch ? max(chinWidth, min(430, vm.closedNotchSize.width + 220)) : max(chinWidth, 320)
        } else if shouldShowDownloadClosedAlert {
            chinWidth = hasPhysicalNotch ? max(chinWidth, min(400, vm.closedNotchSize.width + 190)) : max(chinWidth, 300)
        } else if shouldShowSystemPulseClosedAlert {
            chinWidth = max(chinWidth, min(330, vm.closedNotchSize.width + 150))
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if Defaults[.devClosedStatusEnabled]
            && devStatusManager.activeStatus != nil
            && !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
        {
            chinWidth = max(chinWidth, min(280, vm.closedNotchSize.width + 95))
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }

            if Defaults[.clipboardPreviewEnabled],
               clipboardPreviewManager.currentPreview != nil,
               vm.notchState == .closed,
               !vm.hideOnClosed {
                ClipboardPreviewTooltip()
                    .offset(y: max(32, vm.effectiveClosedNotchHeight + 10))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: clipboardPreviewEnabled) { _, enabled in
            enabled ? clipboardPreviewManager.start() : clipboardPreviewManager.stop()
        }
        .onChange(of: systemPulseEnabled) { _, enabled in
            enabled ? systemPulseManager.start() : systemPulseManager.stop()
        }
        .onChange(of: meetingCompanionEnabled) { _, enabled in
            enabled ? meetingCompanionManager.start() : meetingCompanionManager.stop()
        }
        .onChange(of: downloadWatcherEnabled) { _, enabled in
            enabled ? downloadWatcherManager.start() : downloadWatcherManager.stop()
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if shouldShowMeetingClosedAlert {
                          MeetingClosedLiveActivity()
                              .frame(alignment: .center)
                      } else if shouldShowDownloadClosedAlert {
                          DownloadClosedLiveActivity()
                              .frame(alignment: .center)
                      } else if shouldShowSystemPulseClosedAlert {
                          SystemPulseClosedLiveActivity()
                              .frame(alignment: .center)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if Defaults[.devClosedStatusEnabled]
                          && devStatusManager.activeStatus != nil
                          && !coordinator.expandingView.show
                          && vm.notchState == .closed
                          && !vm.hideOnClosed {
                          DevClosedLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .overlay(alignment: .topLeading) {
                  if Defaults[.showClosedNotchPet] && vm.notchState == .closed && !vm.hideOnClosed {
                      ClosedNotchPetView(state: closedNotchPetState)
                          .frame(width: computedChinWidth, height: max(28, vm.effectiveClosedNotchHeight), alignment: .leading)
                          .padding(.leading, 6)
                          .transition(.opacity.combined(with: .scale(scale: 0.8)))
                          .zIndex(3)
                  }
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .dev:
                        DevStatusView()
                    case .systemPulse:
                        SystemPulseView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    private var hasPhysicalNotch: Bool {
        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        return (currentScreen?.safeAreaInsets.top ?? 0) > 0
    }

    private var mediaIsActive: Bool {
        musicManager.isPlaying || !musicManager.isPlayerIdle
    }

    private var shouldShowMeetingClosedAlert: Bool {
        Defaults[.meetingCompanionEnabled]
            && Defaults[.meetingCompanionClosedAlertEnabled]
            && meetingCompanionManager.snapshot.isActive
            && !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
            && (Defaults[.meetingCompanionShowOverMedia] || !mediaIsActive)
    }

    private var shouldShowDownloadClosedAlert: Bool {
        Defaults[.downloadWatcherEnabled]
            && Defaults[.downloadWatcherClosedAlertEnabled]
            && downloadWatcherManager.snapshot.isVisible
            && !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
            && (Defaults[.downloadWatcherShowOverMedia] || !mediaIsActive)
    }

    private var shouldShowSystemPulseClosedAlert: Bool {
        Defaults[.systemPulseEnabled]
            && Defaults[.systemPulseClosedAlertEnabled]
            && (Defaults[.systemPulseClosedShowFans] || Defaults[.systemPulseClosedShowTemperature])
            && systemPulseManager.snapshot.shouldShowClosedAlert
            && !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
    }

    private var closedNotchPetState: ClosedNotchPetState {
        if systemPulseManager.snapshot.severity >= .high {
            return .hot
        }
        if musicManager.isPlaying || !musicManager.isPlayerIdle {
            return .music
        }
        if devStatusManager.activeStatus?.hasChanges == true {
            return .working
        }
        if batteryModel.isCharging || batteryModel.isPluggedIn {
            return .charging
        }
        return .idle
    }

    private func closedSystemPulseMetrics(for snapshot: SystemPulseSnapshot) -> [String] {
        var metrics: [String] = []

        if Defaults[.systemPulseClosedShowFans], let fanRPM = snapshot.fanRPM {
            metrics.append("\(fanRPM) RPM")
        }

        if Defaults[.systemPulseClosedShowTemperature], let temperature = snapshot.temperatureCelsius {
            metrics.append("\(Int(temperature.rounded()))°C")
        }

        return metrics
    }

    @ViewBuilder
    func MeetingClosedLiveActivity() -> some View {
        let snapshot = meetingCompanionManager.snapshot
        Button {
            meetingCompanionManager.joinMeeting()
        } label: {
            if hasPhysicalNotch {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.joinURL == nil ? "calendar" : "video.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(snapshot.statusText)
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.effectiveAccent)
                    .frame(width: 96, alignment: .trailing)

                    Rectangle()
                        .fill(.black)
                        .frame(width: max(80, vm.closedNotchSize.width - 18))

                    Text(snapshot.compactTitle)
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 116, alignment: .leading)
                }
                .padding(.horizontal, 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: snapshot.joinURL == nil ? "calendar" : "video.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.effectiveAccent)
                    Text(snapshot.statusText)
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.effectiveAccent)
                    Text(snapshot.compactTitle)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 14)
            }
        }
        .buttonStyle(.plain)
        .frame(width: computedChinWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
        .help(snapshot.joinURL == nil ? "Open meeting in Calendar" : "Join meeting")
    }

    @ViewBuilder
    func DownloadClosedLiveActivity() -> some View {
        let snapshot = downloadWatcherManager.snapshot
        Button {
            downloadWatcherManager.revealCurrentDownload()
        } label: {
            let isDone = snapshot.state == .completed
            let isFailed = snapshot.state == .failed
            let tint: Color = isFailed ? .red : (isDone ? .green : Color.effectiveAccent)
            let icon = isFailed ? "exclamationmark.circle.fill" : (isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
            let compactStatus = isFailed ? "Failed" : (isDone ? "Done" : snapshot.formattedBytes)

            if hasPhysicalNotch {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(compactStatus)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }
                    .foregroundStyle(tint)
                    .frame(width: 92, alignment: .trailing)

                    Rectangle()
                        .fill(.black)
                        .frame(width: max(80, vm.closedNotchSize.width - 18))

                    Text(snapshot.fileName)
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 106, alignment: .leading)
                }
                .padding(.horizontal, 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                    Text(snapshot.title)
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text(snapshot.fileName)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
            }
        }
        .buttonStyle(.plain)
        .frame(width: computedChinWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
        .help("Reveal download in Finder")
    }

    @ViewBuilder
    func SystemPulseClosedLiveActivity() -> some View {
        let snapshot = systemPulseManager.snapshot
        let metrics = closedSystemPulseMetrics(for: snapshot)
        let leftMetric = metrics.first ?? snapshot.primaryMetric
        let rightMetric = metrics.dropFirst().first ?? ""

        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: snapshot.severity.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .symbolEffect(.pulse, options: .repeating, value: snapshot.severity)

                Text(leftMetric)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .lineLimit(1)
            }
            .foregroundStyle(snapshot.severity.color)
            .frame(width: 78, alignment: .trailing)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            Text(rightMetric)
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 82, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(width: computedChinWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
        .help("System Pulse: \(metrics.joined(separator: " · "))")
    }

    @ViewBuilder
    func ClipboardPreviewTooltip() -> some View {
        if let preview = clipboardPreviewManager.currentPreview {
            HStack(spacing: 10) {
                Image(systemName: preview.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.effectiveAccent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preview.title)
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(preview.subtitle)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let hint = clipboardPreviewActionHint(for: preview) {
                        Text(hint)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.effectiveAccent.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: 280, alignment: .leading)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                performClipboardPreviewAction(preview)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help(clipboardPreviewActionHint(for: preview) ?? preview.title)
        }
    }

    private func clipboardPreviewActionHint(for preview: ClipboardPreview) -> String? {
        switch preview.kind {
        case .url:
            return "Click to open"
        case .filePath:
            return "Click to reveal"
        case .json, .branch:
            return nil
        }
    }

    private func performClipboardPreviewAction(_ preview: ClipboardPreview) {
        switch preview.kind {
        case .url:
            if let url = URL(string: preview.copiedText) {
                NSWorkspace.shared.open(url)
                clipboardPreviewManager.dismissPreview()
            }
        case .filePath:
            let expanded = (preview.copiedText as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: expanded) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                clipboardPreviewManager.dismissPreview()
            } else {
                let parent = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: parent.path) {
                    NSWorkspace.shared.open(parent)
                    clipboardPreviewManager.dismissPreview()
                }
            }
        case .json, .branch:
            break
        }
    }

    @ViewBuilder
    func DevClosedLiveActivity() -> some View {
        if let status = devStatusManager.activeStatus {
            HStack(spacing: 8) {
                Image(systemName: status.hasChanges ? "circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(status.hasChanges ? .orange : .green)

                Text(status.displayName)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(status.branch)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                    .lineLimit(1)

                Text(status.hasChanges ? "\(status.dirtyCount) changes" : "clean")
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(status.hasChanges ? .semibold : .regular)
                    .foregroundStyle(status.hasChanges ? .orange : .green)
                    .lineLimit(1)

                Text("# \(status.lastCommitShortHash)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(width: computedChinWidth, height: vm.effectiveClosedNotchHeight, alignment: .center)
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

private enum ClosedNotchPetState {
    case idle
    case music
    case hot
    case working
    case charging

    var color: Color {
        switch self {
        case .idle: return .effectiveAccent
        case .music: return .purple
        case .hot: return .orange
        case .working: return .yellow
        case .charging: return .green
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "sparkles"
        case .music: return "music.note"
        case .hot: return "drop.fill"
        case .working: return "hammer.fill"
        case .charging: return "bolt.fill"
        }
    }
}

private struct ClosedNotchPetView: View {
    let state: ClosedNotchPetState
    @State private var bounce = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(state.color.opacity(0.18))
                    .frame(width: 28, height: 28)
                    .blur(radius: 5)

                ClosedPetCreature(color: state.color)
                    .frame(width: 28, height: 24)
                    .rotationEffect(.degrees(bounce ? 5 : -5))
                    .offset(y: bounce ? -1 : 1)
            }

            Image(systemName: state.symbol)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 12, height: 12)
                .background(state.color, in: Circle())
                .offset(x: 5, y: -5)
        }
        .frame(width: 38, height: 28)
        .onAppear { bounce = true }
        .animation(.easeInOut(duration: state == .music ? 0.26 : 1.15).repeatForever(autoreverses: true), value: bounce)
        .allowsHitTesting(false)
    }
}

private struct ClosedPetCreature: View {
    let color: Color

    var body: some View {
        ZStack {
            // ears
            HStack(spacing: 12) {
                Triangle()
                    .fill(color.opacity(0.95))
                    .frame(width: 9, height: 8)
                    .rotationEffect(.degrees(-22))
                Triangle()
                    .fill(color.opacity(0.95))
                    .frame(width: 9, height: 8)
                    .rotationEffect(.degrees(22))
            }
            .offset(y: -10)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.98), color.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: color.opacity(0.32), radius: 5)

            HStack(spacing: 5) {
                Circle().fill(.black.opacity(0.8)).frame(width: 3.6, height: 3.6)
                Circle().fill(.black.opacity(0.8)).frame(width: 3.6, height: 3.6)
            }
            .offset(y: -3)

            ClosedSmileShape()
                .stroke(.black.opacity(0.66), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 8, height: 4)
                .offset(y: 5)
        }
    }
}

private struct ClosedSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
