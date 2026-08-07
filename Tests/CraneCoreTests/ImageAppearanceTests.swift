import Foundation
import Testing

@testable import CraneCore

@Suite("Image identity")
struct ImageAppearanceTests {
    @Test("A reference is reduced to its repository name")
    func stripsRegistryAndTag() {
        #expect(ImageAppearance.repositoryName(from: "docker.io/library/postgres:17-alpine") == "postgres")
        #expect(ImageAppearance.repositoryName(from: "redis") == "redis")
        #expect(ImageAppearance.repositoryName(from: "ghcr.io/apple/container@sha256:abc") == "container")
        #expect(ImageAppearance.repositoryName(from: "registry:5000/team/api:v2") == "api")
    }

    @Test("Known software keeps the same look regardless of registry or tag")
    func recognisesKnownImages() {
        let a = ImageAppearance.of(image: "postgres:17")
        let b = ImageAppearance.of(image: "docker.io/library/postgres:15-alpine")
        #expect(a == b)
        #expect(a.symbol != nil)
    }

    @Test("Unknown images get a stable monogram and colour, never a wrong symbol")
    func fallsBackToMonogram() {
        let mine = ImageAppearance.of(image: "ghcr.io/acme/billing-api:1.4")
        #expect(mine.symbol == nil)
        #expect(mine.monogram == "BI")
        #expect(mine == ImageAppearance.of(image: "ghcr.io/acme/billing-api:2.0"),
                "the same repository must look identical across tags")
        #expect(mine.hue != ImageAppearance.of(image: "ghcr.io/acme/payments-api:1.0").hue,
                "different repositories should be distinguishable")
    }

    @Test("Every hue is a usable colour value")
    func huesAreNormalised() {
        for image in ["postgres", "weird_name_42", "a", "docker.io/x/y:z"] {
            let hue = ImageAppearance.of(image: image).hue
            #expect(hue >= 0 && hue <= 1)
        }
    }
}
