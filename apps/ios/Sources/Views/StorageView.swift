// Storage memory — the half of "where is my X?" that no floor plan can
// answer, because the X lives INSIDE something: a moving box, the hall
// closet, that drawer. A StorageSpot holds things (and other spots);
// photograph an open box and the AI turns the photo into an itemized,
// searchable contents list; print the QR label and pointing any camera
// at the box answers what's in it. Nobody re-scans a room to find the
// tape — they ask the box.
import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI

struct StorageView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StorageSpot.createdAt, order: .reverse)
    private var spots: [StorageSpot]
    @Query private var things: [Thing]
    @Query private var rooms: [Room]
    @State private var adding = false

    var body: some View {
        List {
            if spots.isEmpty {
                ContentUnavailableView(
                    "No storage yet", systemImage: "shippingbox",
                    description: Text("Add a box, closet or drawer, "
                        + "photograph what's inside, and it becomes "
                        + "searchable forever."))
            }
            ForEach(spots.filter { $0.parentID == nil }) { spot in
                NavigationLink {
                    SpotDetailView(spot: spot)
                } label: {
                    SpotRow(spot: spot, spots: spots, things: things,
                            rooms: rooms)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Storage")
        .brandBackground()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddSpotSheet(parentID: nil)
        }
    }

    private func delete(at offsets: IndexSet) {
        let top = spots.filter { $0.parentID == nil }
        for index in offsets {
            deleteSpot(top[index], spots: spots, things: things,
                       context: context)
        }
    }
}

/// Removing a spot never removes the things in it — they fall back to
/// "somewhere", which is honest. Children collapse up a level.
func deleteSpot(_ spot: StorageSpot, spots: [StorageSpot],
                things: [Thing], context: ModelContext) {
    for thing in things where thing.storageID == spot.id {
        thing.storageID = nil
    }
    for child in spots where child.parentID == spot.id {
        child.parentID = spot.parentID
    }
    Store.deleteSpotBlobs(spot.id)
    context.delete(spot)
}

struct SpotRow: View {
    let spot: StorageSpot
    let spots: [StorageSpot]
    let things: [Thing]
    let rooms: [Room]

    var body: some View {
        HStack(spacing: 12) {
            if let photo = Store.loadSpotPhoto(spot.id) {
                Image(uiImage: photo)
                    .resizable().scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: spot.kindSymbol)
                    .font(.title3)
                    .foregroundStyle(Color.brandThread)
                    .frame(width: 46, height: 46)
                    .background(.thinMaterial,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name).font(.headline)
                HStack(spacing: 5) {
                    let count = things.filter {
                        $0.storageID == spot.id
                    }.count
                    let children = spots.filter {
                        $0.parentID == spot.id
                    }.count
                    Text(count == 1 ? "1 item" : "\(count) items")
                    if children > 0 {
                        Text("· \(children) inside")
                    }
                    if let roomID = spot.roomID,
                       let room = rooms.first(where: { $0.id == roomID }) {
                        Text("· \(room.name)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// ---- add a spot ------------------------------------------------------------

struct AddSpotSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var rooms: [Room]
    let parentID: UUID?
    @State private var name = ""
    @State private var kind = "box"
    @State private var roomID: UUID?

    private static let kinds: [(String, String)] = [
        ("box", "Box"), ("bin", "Bin"), ("closet", "Closet"),
        ("drawer", "Drawer"), ("shelf", "Shelf"),
        ("cabinet", "Cabinet"), ("other", "Other"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name — \"Moving box 3\", \"Hall closet\"…",
                          text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(Self.kinds, id: \.0) { value, title in
                        Text(title).tag(value)
                    }
                }
                if !rooms.isEmpty {
                    Picker("Room (optional)", selection: $roomID) {
                        Text("None").tag(UUID?.none)
                        ForEach(rooms) { room in
                            Text(room.name).tag(UUID?.some(room.id))
                        }
                    }
                }
            }
            .navigationTitle(parentID == nil
                             ? "New storage" : "New inside this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(
                            in: .whitespaces)
                        let spot = StorageSpot(
                            name: trimmed.isEmpty ? "Box" : trimmed,
                            kind: kind, roomID: roomID,
                            parentID: parentID)
                        context.insert(spot)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// ---- spot detail -----------------------------------------------------------

struct SpotDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var spot: StorageSpot
    @Query private var spots: [StorageSpot]
    @Query private var things: [Thing]
    @Query private var rooms: [Room]
    @ObservedObject private var ai = AIService.shared
    @State private var showCamera = false
    @State private var itemizing = false
    @State private var proposed: [AIItem] = []
    @State private var picked: Set<UUID> = []
    @State private var aiError: String?
    /// Several angles of one shelf/box; the AI reads them together
    /// and each accepted item gets a thumbnail cropped from the
    /// photo it was seen in.
    @State private var pendingPhotos: [UIImage] = []
    @State private var addingChild = false
    @State private var quickName = ""
    @State private var labelURL: URL?

    private var contents: [Thing] {
        things.filter { $0.storageID == spot.id }
            .sorted { $0.displayName < $1.displayName }
    }

    private var children: [StorageSpot] {
        spots.filter { $0.parentID == spot.id }
    }

    var body: some View {
        List {
            if let photo = Store.loadSpotPhoto(spot.id) {
                Section {
                    Image(uiImage: photo)
                        .resizable().scaledToFill()
                        .frame(maxHeight: 220)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                Button {
                    showCamera = true
                } label: {
                    Label(pendingPhotos.isEmpty
                          ? "Photograph contents"
                          : "Add another angle (\(pendingPhotos.count) so far)",
                          systemImage: "camera.on.rectangle")
                }
                if !pendingPhotos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pendingPhotos.enumerated()),
                                    id: \.offset) { _, photo in
                                Image(uiImage: photo)
                                    .resizable().scaledToFill()
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: 8))
                            }
                        }
                    }
                    Button {
                        itemize()
                    } label: {
                        HStack {
                            Label("Itemize \(pendingPhotos.count) "
                                  + "photo(s) with AI",
                                  systemImage: "sparkles")
                            Spacer()
                            if itemizing {
                                ThreadLoadingView(size: 24)
                            }
                        }
                    }
                    .disabled(!ai.isConfigured || itemizing)
                    if itemizing, let status = ai.batchStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !ai.isConfigured {
                    Text("Add a free AI key in Settings and photos "
                         + "of the open box become a full contents "
                         + "list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Add an item by name…", text: $quickName)
                        .onSubmit(quickAdd)
                    Button("Add", action: quickAdd)
                        .disabled(quickName.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                }
                Button {
                    labelURL = QRLabel.render(spot: spot)
                } label: {
                    Label("Print QR label",
                          systemImage: "qrcode")
                }
            } footer: {
                Text("Stick the label on the \(spot.kind); pointing "
                     + "the iPhone camera at it opens this list.")
            }

            if !proposed.isEmpty {
                Section("Found in the photos — keep what's right") {
                    ForEach(proposed) { item in
                        Button {
                            if picked.contains(item.id) {
                                picked.remove(item.id)
                            } else {
                                picked.insert(item.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked.contains(item.id)
                                      ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(Color.brandThread)
                                if let box = item.box,
                                   item.photoIndex < pendingPhotos.count,
                                   let thumb = AIService.crop(
                                    pendingPhotos[item.photoIndex],
                                    box: box) {
                                    Image(uiImage: thumb)
                                        .resizable().scaledToFill()
                                        .frame(width: 38, height: 38)
                                        .clipShape(RoundedRectangle(
                                            cornerRadius: 7))
                                }
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                VStack(alignment: .trailing,
                                       spacing: 1) {
                                    if let v = item.estimatedValue {
                                        Text(v.formatted(.currency(
                                            code: Locale.current
                                                .currency?.identifier
                                                ?? "USD")
                                            .precision(
                                                .fractionLength(0))))
                                            .font(.caption)
                                            .foregroundStyle(
                                                .secondary)
                                    }
                                    if let c = item.confidence {
                                        Text("\(Int(c * 100))% sure")
                                            .font(.caption2)
                                            .foregroundStyle(
                                                .tertiary)
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        acceptProposed()
                    } label: {
                        Label("Add \(picked.count) items",
                              systemImage: "tray.and.arrow.down")
                    }
                    .disabled(picked.isEmpty)
                }
            }

            if let aiError {
                Section {
                    Label(aiError, systemImage: "bolt.horizontal")
                        .font(.caption)
                        .foregroundStyle(Color.brandDotCool)
                }
            }

            if !children.isEmpty {
                Section("Inside") {
                    ForEach(children) { child in
                        NavigationLink {
                            SpotDetailView(spot: child)
                        } label: {
                            SpotRow(spot: child, spots: spots,
                                    things: things, rooms: rooms)
                        }
                    }
                }
            }

            Section(contents.isEmpty
                    ? "Nothing logged inside yet"
                    : "Contents — \(contents.count)") {
                ForEach(contents) { thing in
                    HStack(spacing: 12) {
                        ThingThumbnail(thingID: thing.id)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(thing.displayName).font(.callout)
                            if let price = thing.price {
                                Text(price.formatted(.currency(
                                    code: Locale.current.currency?
                                        .identifier ?? "USD")
                                    .precision(.fractionLength(0)))
                                    + (thing.priceSource == "ai"
                                       ? " · AI estimate" : ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Store.deleteThingBlobs(thing.id)
                            context.delete(thing)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            thing.storageID = nil
                        } label: {
                            Label("Take out",
                                  systemImage: "tray.and.arrow.up")
                        }
                        .tint(.orange)
                    }
                }
            }

            Section {
                Button {
                    addingChild = true
                } label: {
                    Label("Add a box/shelf inside",
                          systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    deleteSpot(spot, spots: spots, things: things,
                               context: context)
                    dismiss()
                } label: {
                    Label("Delete \(spot.name)", systemImage: "trash")
                }
            }
        }
        .navigationTitle(spot.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .brandBackground()
        .sheet(isPresented: $showCamera) {
            CameraSheet { image in
                pendingPhotos.append(image)
                if pendingPhotos.count == 1,
                   let data = image.jpegData(
                    compressionQuality: 0.8) {
                    Store.saveSpotPhoto(data, spotID: spot.id)
                }
            }
        }
        .sheet(isPresented: $addingChild) {
            AddSpotSheet(parentID: spot.id)
        }
        .sheet(item: $labelURL) { url in
            ShareURLSheet(url: url)
        }
    }

    private func quickAdd() {
        let trimmed = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        insertThing(name: trimmed, category: "object", value: nil,
                    source: "")
        quickName = ""
    }

    private func itemize() {
        guard !pendingPhotos.isEmpty else { return }
        itemizing = true
        aiError = nil
        proposed = []
        Task {
            do {
                let items = try await ai.itemizeBox(
                    images: pendingPhotos)
                proposed = items
                picked = Set(items.map(\.id))
                if items.isEmpty {
                    aiError = "The AI saw nothing it could name — try "
                        + "a closer, brighter photo."
                }
            } catch {
                aiError = error.localizedDescription
            }
            itemizing = false
        }
    }

    private func acceptProposed() {
        for item in proposed where picked.contains(item.id) {
            let thing = insertThing(
                name: item.name, category: item.category,
                value: item.estimatedValue, source: "ai")
            if let c = item.confidence {
                thing.autoConfidence = c
            }
            // its own thumbnail, cropped out of the shelf photo
            if let box = item.box,
               item.photoIndex < pendingPhotos.count,
               let thumb = AIService.crop(
                pendingPhotos[item.photoIndex], box: box) {
                Store.saveThumb(thumb, thingID: thing.id)
            }
        }
        proposed = []
        picked = []
        pendingPhotos = []
    }

    /// Contents have a home (this spot) but no floor-plan pin — that is
    /// the entire point of storage memory.
    @discardableResult
    private func insertThing(name: String, category: String,
                             value: Double?, source: String) -> Thing {
        let thing = Thing(displayName: name, autoLabel: name,
                          autoConfidence: 0, category: category,
                          positionX: 0, positionY: 0, heightM: 0,
                          widthM: 0, sizeHeightM: 0, sizeConfidence: 0)
        thing.hasPosition = false
        thing.storageID = spot.id
        thing.userNamed = source.isEmpty   // typed names are yours
        thing.price = value
        thing.priceSource = value == nil ? "" : source
        if let roomID = spot.roomID {
            thing.room = rooms.first { $0.id == roomID }
        }
        context.insert(thing)
        SpotlightIndex.index(thing, location: "In \(spot.name)")
        return thing
    }
}

// ---- open a spot by id (QR scan, deep link, Spotlight) ---------------------

extension UUID: Identifiable {
    public var id: String { uuidString }
}

struct SpotByIDSheet: View {
    let id: UUID
    @Query private var spots: [StorageSpot]

    var body: some View {
        NavigationStack {
            if let spot = spots.first(where: { $0.id == id }) {
                SpotDetailView(spot: spot)
            } else {
                ContentUnavailableView(
                    "Label not recognized",
                    systemImage: "qrcode",
                    description: Text("This QR belongs to a storage "
                        + "spot that no longer exists."))
            }
        }
    }
}

// ---- QR labels -------------------------------------------------------------

enum QRLabel {
    /// A printable label: big QR (theseus://spot/<id>) + the spot's
    /// name. The iPhone's own camera reads the code and deep-links
    /// straight into the contents list.
    static func render(spot: StorageSpot) -> URL? {
        let payload = "theseus://spot/\(spot.id.uuidString)"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scale = 560 / ci.extent.width
        let scaled = ci.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext()
        guard let cg = ciContext.createCGImage(scaled,
                                               from: scaled.extent) else {
            return nil
        }
        let qr = UIImage(cgImage: cg)

        let size = CGSize(width: 700, height: 860)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rctx in
            UIColor.white.setFill()
            rctx.fill(CGRect(origin: .zero, size: size))
            qr.draw(in: CGRect(x: 70, y: 60, width: 560, height: 560))
            let name = NSAttributedString(
                string: spot.name,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 52, weight: .bold),
                    .foregroundColor: UIColor.black,
                ])
            let nameSize = name.size()
            name.draw(at: CGPoint(x: (size.width - nameSize.width) / 2,
                                  y: 650))
            let sub = NSAttributedString(
                string: "Scan with your camera — Theseus",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 26,
                                             weight: .regular),
                    .foregroundColor: UIColor.darkGray,
                ])
            let subSize = sub.size()
            sub.draw(at: CGPoint(x: (size.width - subSize.width) / 2,
                                 y: 650 + nameSize.height + 14))
        }
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theseus-label-\(spot.id).png")
        try? data.write(to: url, options: .atomic)
        return url
    }
}
