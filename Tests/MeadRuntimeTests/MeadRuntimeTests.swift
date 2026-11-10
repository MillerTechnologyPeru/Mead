import MeadRuntime
import Testing

@Test func artStartsWithItsClassPathAndLibraryPath() {
    #expect(ART.options(classPath: ["/a.dex", "/b.dex"], libraryPath: ["/lib/one", "/lib/two"], extra: ["-Xusejit:false"]) == [
        "-Djava.class.path=/a.dex:/b.dex",
        "-Djava.library.path=/lib/one:/lib/two",
        "-Xusejit:false",
    ])
    #expect(ART.options(classPath: [], libraryPath: []).isEmpty)
}
