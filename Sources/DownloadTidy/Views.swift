import SwiftUI
import AppKit
import QuickLookUI
import TidyCore

private let ink = Color(red: 0.13, green: 0.19, blue: 0.23)
private let teal = Color(red: 0.13, green: 0.43, blue: 0.38)
private let canvas = Color(red: 0.97, green: 0.97, blue: 0.95)
private let muted = Color(red: 0.47, green: 0.50, blue: 0.51)
private let line = Color.black.opacity(0.07)

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 204)
            Rectangle().fill(line).frame(width: 1)
            VStack(spacing: 0) {
                header
                if model.needsFolder {
                    emptyState("다운로드 폴더부터 연결해요", detail: "폴더를 한 번 선택하면 파일을 한눈에 살펴볼 수 있어요.\n정리할 파일과 이동 위치는 직접 확인하고 결정해요.", symbol: "folder.badge.plus")
                    Button("다운로드 폴더 연결") { model.chooseFolder() }.buttonStyle(.borderedProminent).controlSize(.large).padding(.bottom, 80)
                } else if let error = model.scanError {
                    emptyState("폴더를 열 수 없어요", detail: error + "\n아래 버튼으로 폴더를 다시 선택해 주세요.", symbol: "folder.badge.questionmark")
                    Button("폴더 선택") { model.chooseFolder() }.padding(.bottom, 40)
                } else {
                    overview
                    searchBar
                    filters
                    HStack(spacing: 0) {
                        fileList.frame(minWidth: 360, maxWidth: .infinity)
                        Rectangle().fill(line).frame(width: 1)
                        inspector.frame(width: 266)
                    }
                }
                footer
            }.background(Color.white)
        }
        .foregroundStyle(ink).tint(teal)
        .frame(minWidth: 1020, minHeight: 680)
        .preferredColorScheme(.light)
        .sheet(isPresented: $model.showPlan) { PlanView(model: model) }
        .sheet(isPresented: $model.showHistory) { HistoryView(model: model) }
        .alert("확인이 필요해요", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("확인") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.query) { _ in model.search() }
        .onChange(of: model.contentEnabled) { _ in model.search() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 21)).foregroundStyle(teal)
                Text("다운정리").font(.system(size: 21, weight: .bold, design: .rounded))
            }.padding(.top, 32).padding(.bottom, 6)
            Text("파일마다, 제자리를.").font(.system(size: 11)).foregroundStyle(muted).padding(.leading, 33)
            Text("내 다운로드").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted).padding(.top, 36).padding(.bottom, 12)
            sideRow("모든 파일", symbol: "square.grid.2x2", kind: nil, count: model.entries.count)
            ForEach(FileKind.allCases, id: \.self) { kind in
                sideRow(kind.rawValue, symbol: kind.symbol, kind: kind, count: model.entries.filter { $0.kind == kind }.count)
            }
            Divider().padding(.vertical, 20)
            Button { model.showHistory = true } label: {
                Label("정리 기록", systemImage: "clock.arrow.circlepath").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.buttonStyle(.plain)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("내 맥 안에서만", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)).foregroundStyle(teal)
                Text("파일과 검색 내용은\n이 기기 안에서 처리해요.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.bottom, 20)
        }.padding(.horizontal, 16).background(canvas)
    }
    private func sideRow(_ title: String, symbol: String, kind: FileKind?, count: Int) -> some View {
        Button { model.category = kind; model.selection = [] } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(model.category == kind ? teal : muted)
            }.font(.system(size: 13, weight: model.category == kind ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 10)
                .background(model.category == kind ? teal.opacity(0.10) : .clear)
                .foregroundStyle(model.category == kind ? teal : ink)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.vertical, 1)
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.category?.rawValue ?? "흩어진 파일, 한눈에.").font(.system(size: 26, weight: .bold))
                HStack(spacing: 5) {
                    Image(systemName: "folder"); Text(model.root.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                }.font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle).help(model.root.path)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).padding(9).help("새로고침 (⌘R)").keyboardShortcut("r", modifiers: .command).disabled(model.working)
            Button("폴더 변경") { model.chooseFolder() }.buttonStyle(.bordered).controlSize(.regular).disabled(model.working)
        }.padding(.horizontal, 28).padding(.top, 27).padding(.bottom, 23)
    }
    private var overview: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("다운로드 속 파일").font(.system(size: 11)).foregroundStyle(muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(model.fileCount)").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("개").font(.system(size: 12)).foregroundStyle(muted)
                    Spacer()
                    Text(bytes(model.totalSize)).font(.system(size: 11)).foregroundStyle(muted)
                }
            }.padding(17).frame(maxWidth: .infinity).background(canvas).clipShape(RoundedRectangle(cornerRadius: 13))
            Button {
                model.query = ""; model.period = 0; model.category = .installer; model.selection = []
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("설치 파일 모아보기", systemImage: "shippingbox"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11, weight: .medium))
                    Text("\(model.entries.filter { $0.kind == .installer }.count)개를 한곳에서 확인해요").font(.system(size: 14, weight: .semibold))
                }.padding(17).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading).background(Color(red: 0.98, green: 0.94, blue: 0.86)).clipShape(RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain)
            Button {
                model.query = ""; model.period = 0; model.category = nil
                model.selection = Set(model.ready.map(\.id))
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("종류별 정리 제안", systemImage: "tray.2"); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 11, weight: .medium))
                    Text("\(model.ready.count)개 선택하고 검토하기").font(.system(size: 14, weight: .semibold))
                }.padding(17).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading).background(teal.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).disabled(model.working || model.storageError != nil)
        }.padding(.horizontal, 28).padding(.bottom, 23)
    }
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(teal)
            TextField("파일 이름이나 기억나는 문장으로 찾아보세요", text: $model.query).textFieldStyle(.plain).font(.system(size: 13))
            if model.searching { ProgressView().controlSize(.small) }
            if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(muted) }.buttonStyle(.plain) }
            Divider().frame(height: 18)
            Toggle("내용 검색", isOn: $model.contentEnabled).toggleStyle(.checkbox).font(.system(size: 11)).help("텍스트 PDF: 20MB 이하, 앞 80쪽 · UTF-8 TXT/MD/CSV/TSV/LOG: 1MB 이하. 스캔 PDF와 HWP·Office 문서는 파일명으로 검색합니다.")
        }.padding(13).background(canvas).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line)).padding(.horizontal, 28)
    }
    private var filters: some View {
        HStack(spacing: 5) {
            ForEach(Array(["전체 기간", "오늘", "최근 7일", "30일 이전"].enumerated()), id: \.offset) { index, title in
                Button { model.period = index } label: {
                    Text(title).font(.system(size: 11, weight: model.period == index ? .semibold : .regular)).padding(.horizontal, 11).padding(.vertical, 7)
                        .background(model.period == index ? ink : .clear).foregroundStyle(model.period == index ? .white : muted).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            Spacer()
            Picker("정렬", selection: $model.sort) { Text("최근 추가순").tag(0); Text("이름순").tag(1); Text("큰 파일순").tag(2) }.labelsHidden().frame(width: 120).controlSize(.small)
        }.padding(.horizontal, 28).padding(.vertical, 17)
    }
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let ids = Set(model.filtered.filter(\.canOrganize).map(\.id))
                    if !ids.isEmpty && ids.isSubset(of: model.selection) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
                } label: { Image(systemName: !model.filtered.filter(\.canOrganize).isEmpty && Set(model.filtered.filter(\.canOrganize).map(\.id)).isSubset(of: model.selection) ? "checkmark.square.fill" : "square").foregroundStyle(muted) }.buttonStyle(.plain).help("현재 목록의 정리 가능한 파일 선택").disabled(model.working || model.storageError != nil)
                Text("파일 \(model.filtered.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Text("추가일 · 크기").font(.system(size: 10)).foregroundStyle(muted)
            }.padding(.horizontal, 28).padding(.vertical, 11).background(canvas.opacity(0.7))
            if model.filtered.isEmpty {
                emptyState(model.loading ? "파일을 읽고 있어요" : model.query.isEmpty ? "아직 파일이 없어요" : "일치하는 파일이 없어요", detail: model.query.isEmpty ? "다른 분류나 기간도 살펴보세요." : "짧은 단어나 파일 확장자로 다시 찾아보세요.", symbol: "tray")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filtered) { entry in FileRow(entry: entry, model: model) }
                    }
                }
            }
        }
    }
    private var inspector: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 13) {
            Text("미리보기").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
            if let entry = model.focused {
                if entry.kind != .folder && entry.exclusion == nil {
                    QuickPreview(url: entry.url).frame(height: 165).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    Image(systemName: entry.kind.symbol).font(.system(size: 50, weight: .light)).foregroundStyle(teal).frame(maxWidth: .infinity).frame(height: 150)
                }
                Text(entry.name).font(.system(size: 14, weight: .semibold)).lineLimit(4).textSelection(.enabled)
                VStack(spacing: 10) {
                    detail("종류", entry.kind.rawValue)
                    detail("크기", entry.kind == .folder ? "—" : bytes(entry.size))
                    detail("추가일", entry.added.formatted(.dateTime.year().month().day()))
                    detail("위치", entry.organized ? entry.url.deletingLastPathComponent().lastPathComponent : model.root.lastPathComponent)
                }
                if let reason = entry.exclusion { Text(reason).font(.system(size: 11)).foregroundStyle(.orange) }
                if model.contentMatches.contains(entry.id) { Label("문서 내용에서 찾았어요", systemImage: "text.magnifyingglass").font(.system(size: 11)).foregroundStyle(teal) }
                HStack {
                    Button("열기") { model.open(entry) }.buttonStyle(.borderedProminent)
                    Button("Finder에서 보기") { model.reveal(entry) }.buttonStyle(.bordered)
                }.controlSize(.small)
                Spacer(minLength: 0)
                Text(entry.organized ? "종류별 폴더에 정리된 파일이에요." : entry.canOrganize ? "정리하면 ‘\(entry.kind.rawValue)’ 폴더로 이동해요." : "이 파일은 자동 정리 대상이 아니에요.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(teal.opacity(0.65))
                    Text("열기 전에, 먼저 확인").font(.system(size: 14, weight: .medium))
                    Text("목록에서 파일을 선택하면\n여기에서 미리 볼 수 있어요.").font(.system(size: 11)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxHeight: .infinity).background(canvas.opacity(0.6))
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(muted); Spacer(); Text(value).lineLimit(1) }.font(.system(size: 11))
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            if let message = model.message {
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(teal)
                    Text(message).font(.system(size: 11)).lineLimit(2)
                    Spacer(); Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(.horizontal, 25).padding(.vertical, 10).background(teal.opacity(0.06))
            }
            if let storageError = model.storageError { Text(storageError).font(.system(size: 11)).foregroundStyle(.red).padding(10) }
            HStack(spacing: 12) {
                if model.working {
                    ProgressView().controlSize(.small)
                    Text("파일 상태를 확인하고 처리 중이에요…").font(.system(size: 12))
                    if model.canCancel { Button("남은 작업 중단") { model.cancelOperation() }.controlSize(.small) }
                } else {
                    Text(model.selected.isEmpty ? "필요한 파일을 선택해서 정리해 보세요." : "\(model.selected.count)개 선택 · \(bytes(model.selected.reduce(0) { $0 + $1.size }))").font(.system(size: 12)).foregroundStyle(muted)
                    if !model.selection.isEmpty { Button("선택 해제") { model.selection = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(teal) }
                }
                Spacer()
                Button { model.previewSelection() } label: { Label("정리 미리보기", systemImage: "arrow.right").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.working || model.storageError != nil)
            }.padding(.horizontal, 26).padding(.vertical, 15)
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 13) {
            Button { model.toggle(entry) } label: {
                Image(systemName: model.selection.contains(entry.id) ? "checkmark.square.fill" : "square").foregroundStyle(entry.canOrganize ? teal : muted.opacity(0.25))
            }.buttonStyle(.plain).disabled(!entry.canOrganize || model.working || model.storageError != nil).accessibilityLabel("\(entry.name) 정리 선택")
            Image(systemName: entry.kind.symbol).font(.system(size: 19, weight: .regular)).foregroundStyle(entry.kind == .installer ? Color.orange : teal)
                .frame(width: 38, height: 40).background(entry.kind == .installer ? Color.orange.opacity(0.08) : teal.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.exclusion ?? (entry.organized ? "정리됨 · \(entry.kind.rawValue)" : entry.kind.rawValue))
                    if model.contentMatches.contains(entry.id) { Text("· 내용 일치").foregroundStyle(teal) }
                }.font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Text(entry.added.formatted(.dateTime.month().day()))
                Text(entry.kind == .folder ? "—" : bytes(entry.size))
            }.font(.system(size: 10)).foregroundStyle(muted)
        }.padding(.horizontal, 28).padding(.vertical, 13)
            .background(model.focusID == entry.id ? teal.opacity(0.07) : Color.white)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.open(entry) }
            .onTapGesture { model.focusID = entry.id }
            .onDrag { NSItemProvider(object: entry.url as NSURL) }
            .contextMenu {
                Button("열기") { model.open(entry) }
                Button("Finder에서 보기") { model.reveal(entry) }
                if entry.canOrganize { Button(model.selection.contains(entry.id) ? "정리 선택 해제" : "정리할 파일로 선택") { model.toggle(entry) }.disabled(model.working) }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(line.opacity(0.6)).frame(height: 1).padding(.leading, 78) }
    }
}

private struct QuickPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .compact)! }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 35, weight: .light)).foregroundStyle(teal.opacity(0.6))
        Text(title).font(.system(size: 16, weight: .medium))
        Text(detail).font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(4)
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
}

struct PlanView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("이렇게 정리할게요", systemImage: "tray.and.arrow.down").font(.system(size: 23, weight: .bold)).foregroundStyle(ink)
            Text("선택한 \(model.plans.count)개 파일을 아래 위치로 옮겨요. 같은 이름의 파일은 덮어쓰지 않아요.").font(.system(size: 12)).foregroundStyle(muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.plans) { plan in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(plan.source.lastPathComponent).font(.system(size: 12, weight: .semibold))
                            Text(plan.source.path).font(.system(size: 10)).foregroundStyle(muted)
                            Label(plan.destination.path, systemImage: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(teal)
                        }.textSelection(.enabled).padding(.vertical, 13)
                        Divider()
                    }
                }
            }.frame(minHeight: 200, maxHeight: 350)
            Text("이동 전 파일 상태를 다시 확인해요. 정리 기록은 앱을 껐다 켜도 남으며, 변경되지 않은 파일은 되돌릴 수 있어요.").font(.system(size: 11)).foregroundStyle(muted)
            HStack {
                Button("취소") { model.showPlan = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("\(model.plans.count)개 파일 이동") { model.organize() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650).tint(teal).preferredColorScheme(.light)
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("정리 기록", systemImage: "clock.arrow.circlepath").font(.system(size: 23, weight: .bold))
                Spacer(); Button("닫기") { model.showHistory = false }.keyboardShortcut(.cancelAction)
            }
            Text("되돌리기는 원래 위치가 비어 있고, 정리 후 파일이 변경되지 않았을 때 가능해요.").font(.system(size: 12)).foregroundStyle(muted)
            if model.history.isEmpty { emptyState("아직 정리 기록이 없어요", detail: "파일을 정리하면 이동 내역이 여기에 남아요.", symbol: "clock") }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.history) { batch in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(batch.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Button("이 정리 되돌리기") { model.undo(batch) }.disabled(model.working || !batch.records.contains { $0.state == .moved })
                                }
                                ForEach(batch.records) { record in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: record.state == .moved ? "checkmark.circle" : record.state == .undone ? "arrow.uturn.backward.circle" : "exclamationmark.circle").foregroundStyle(record.state == .failed ? .orange : teal)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(record.plan.source.lastPathComponent).font(.system(size: 12, weight: .medium))
                                            Text(record.plan.destination.path).font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
                                            if let note = record.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
                                        }
                                        Spacer()
                                        Text(record.state.label).font(.system(size: 10)).foregroundStyle(muted)
                                    }
                                }
                            }.padding(16).background(canvas).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if model.working { ProgressView().controlSize(.small) }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(teal) }
        }.padding(28).frame(width: 720, height: 540).foregroundStyle(ink).tint(teal).preferredColorScheme(.light)
    }
}
