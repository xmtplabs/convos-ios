@testable import ConvosConnections
import Testing

@Suite("Photos action schemas")
struct PhotosActionSchemasTests {
    @Test("publishes three actions")
    func publishesThreeActions() {
        let schemas = PhotosActionSchemas.all
        #expect(schemas.count == 3)
        #expect(Set(schemas.map(\.actionName)) == ["save_image", "favorite_asset", "delete_asset"])
    }

    @Test("capabilities")
    func capabilities() {
        #expect(PhotosActionSchemas.saveImage.capability == .writeCreate)
        #expect(PhotosActionSchemas.favoriteAsset.capability == .writeUpdate)
        #expect(PhotosActionSchemas.deleteAsset.capability == .writeDelete)
    }

    @Test("save_image requires imageData")
    func saveImageRequiresImageData() {
        let input = PhotosActionSchemas.saveImage.inputs.first { $0.name == "imageData" }
        #expect(input?.isRequired == true)
    }

    @Test("PhotosDataSink publishes the same schemas")
    func sinkPublishesSchemas() async {
        let sink = PhotosDataSink()
        let schemas = await sink.actionSchemas()
        #expect(schemas == PhotosActionSchemas.all)
    }
}
