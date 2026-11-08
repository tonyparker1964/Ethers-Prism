import XCTest
@testable import EthersPrismCore

final class BeatsTests: XCTestCase {
    func testSamplesAreSortedIntoRolesByNameThenFolder() {
        XCTAssertEqual(SampleScanner.classify(relativePath: "Lazer Dice/Samples/Drums/Kick/Kick LazerDice 1.wav"), .kick)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Kit/BD_Dusty.wav"), .kick)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Drums/Hihat/HH Closed 3.wav"), .closedHat)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Drums/Hihat/Open 1.wav"), .openHat)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Drums/Snare/Thwack.aif"), .snare)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Drums/Clap/Clap Room.wav"), .clap)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Instruments/Bass/808 Long C1.wav"), .bass)
        XCTAssertEqual(SampleScanner.classify(relativePath: "Drums/Percussion/Shaker Fast.wav"), .perc)
        XCTAssertNil(SampleScanner.classify(relativePath: "Loops/Drum Loop 90bpm.wav"))
        XCTAssertNil(SampleScanner.classify(relativePath: "Pads/Warm Pad.wav"))
        XCTAssertEqual(SampleScanner.tokens("OpenHatHH01"), ["open", "hat", "hh", "01"])
    }

    func testKitGroupIsTheFolderAboveSamples() {
        XCTAssertEqual(SampleScanner.group(relativePath: "Expansions/Lazer Dice/Samples/Drums/Kick/K.wav", rootName: "NI"), "Lazer Dice")
        XCTAssertEqual(SampleScanner.group(relativePath: "My Kit/Kick.wav", rootName: "NI"), "My Kit")
        XCTAssertEqual(SampleScanner.group(relativePath: "Kick.wav", rootName: "NI"), "NI")
    }

    func testSameDialsGiveTheSameBeatAndPreviewStartsLikeTheRender() {
        let p = BeatParameters()
        let a = BeatComposer.compose(style: .boomBap, seed: 42, parameters: p, bars: 16)
        let b = BeatComposer.compose(style: .boomBap, seed: 42, parameters: p, bars: 16)
        XCTAssertEqual(a, b)
        let preview = BeatComposer.compose(style: .boomBap, seed: 42, parameters: p, bars: 4)
        // Bar 5 can start a hair early when humanized, so compare up to just before it.
        XCTAssertEqual(preview.events.filter { $0.time < 47.9 }, a.events.filter { $0.time < 47.9 })
        XCTAssertTrue(a.events.contains { $0.role == .kick })
        XCTAssertTrue(a.events.allSatisfy { $0.time >= 0 && $0.time < Double(a.steps) + 1 })
    }

    func testMoreDensityMeansMoreHitsAndTempoStaysInStyle() {
        var sparse = BeatParameters(); sparse.density = 0.1
        var busy = BeatParameters(); busy.density = 0.95
        let s = BeatComposer.compose(style: .trap, seed: 7, parameters: sparse, bars: 4)
        let b = BeatComposer.compose(style: .trap, seed: 7, parameters: busy, bars: 4)
        XCTAssertGreaterThan(b.events.count, s.events.count)
        var fast = BeatParameters(); fast.tempo = 1
        XCTAssertEqual(BeatComposer.compose(style: .house, seed: 1, parameters: fast, bars: 1).bpm, 128)
        XCTAssertEqual(BeatStyle.detect(in: "a dusty lofi beat").id, "lofi")
        XCTAssertEqual(BeatStyle.detect(in: "something").id, "boombap")
        XCTAssertEqual(BeatStyle.detect(in: "dark trap beat").id, "trap")
        XCTAssertEqual(BeatStyle.detect(in: "liquid drum & bass").id, "dnb")
    }

    func testDialsAreReadByName() {
        let dials = [Dial(name: "Tempo", lowPole: "a", highPole: "b", value: 100),
                     Dial(name: "Kit", lowPole: "a", highPole: "b", value: 25)]
        let p = BeatParameters(dials: dials)
        XCTAssertEqual(p.tempo, 1)
        XCTAssertEqual(p.kit, 0.25)
        XCTAssertEqual(p.density, 0.5)
    }

    func testKitChoiceFollowsDialGoalAndRequirements() {
        let files = [
            SampleFile(path: "/x/Alpha/Kick 1.wav", role: .kick, group: "Alpha"),
            SampleFile(path: "/x/Alpha/Snare 1.wav", role: .snare, group: "Alpha"),
            SampleFile(path: "/x/Beta/Kick B.wav", role: .kick, group: "Beta"),
            SampleFile(path: "/x/Beta/Clap B.wav", role: .clap, group: "Beta"),
            SampleFile(path: "/x/Beta/Snare Rusty.wav", role: .snare, group: "Beta")
        ]
        let index = SampleIndex(roots: ["/x"], files: files)
        XCTAssertEqual(BeatsAdapter.choose(from: index, goal: "trap", constraints: [], kit: 0, seed: 1)[.kick]?.group, "Alpha")
        XCTAssertEqual(BeatsAdapter.choose(from: index, goal: "trap", constraints: [], kit: 0.99, seed: 1)[.kick]?.group, "Beta")
        XCTAssertEqual(BeatsAdapter.choose(from: index, goal: "trap with beta", constraints: [], kit: 0, seed: 1)[.kick]?.group, "Beta")
        let avoid = [Constraint(kind: .mustAvoid, text: "rusty")]
        XCTAssertEqual(BeatsAdapter.choose(from: index, goal: "beta", constraints: avoid, kit: 0, seed: 1)[.snare], nil)
    }

    func testWAVAndMIDIAreWellFormed() {
        let plan = BeatComposer.compose(style: .house, seed: 3, parameters: BeatParameters(), bars: 2)
        let audio = BeatMixer.mix(plan, sounds: [:], tone: 1)
        XCTAssertGreaterThan(audio.frames, Int(plan.secondsPerStep * Double(plan.steps) * BeatAudio.sampleRate))
        let wav = BeatAudio.wav(audio)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(wav.count, 44 + audio.frames * 4)
        XCTAssertFalse(BeatAudio.peaks(ofWAV: wav, count: 50).isEmpty)
        let midi = BeatMIDI.file(plan)
        XCTAssertEqual(String(decoding: midi.prefix(4), as: UTF8.self), "MThd")
    }
}

final class ProducerTests: XCTestCase {
    let kits = ["Amplified Funk Library", "Basement Era Library", "Battery 4 Factory Library"]

    func testProducerAnswerIsReadAndCheckedAgainstTheLibrary() throws {
        let raw = #"<think>hmm</think>{"style": "lofi", "kits": ["basement era library", "Not A Real Kit"], "dials": {"tempo": 30, "swing": 140, "mood": 5}, "note": "Dusty and slow."}"#
        let plan = try BeatProducer.parse(raw, kits: kits)
        XCTAssertEqual(plan.style?.id, "lofi")
        XCTAssertEqual(plan.kits, ["Basement Era Library"])
        XCTAssertEqual(plan.dialValues["tempo"], 30)
        XCTAssertEqual(plan.dialValues["swing"], 100)
        XCTAssertNil(plan.dialValues["mood"])
        XCTAssertEqual(try BeatProducer.parse(#"{"style":"Drum and bass","kits":[],"dials":{},"note":""}"#, kits: kits).style?.id, "dnb")
        XCTAssertNil(try BeatProducer.parse(#"{"style":"polka","kits":[],"dials":{},"note":""}"#, kits: kits).style)
    }

    func testPicksBecomeEditableRequirementsAndReplaceEarlierPicks() {
        let mine = Constraint(kind: .mustAvoid, text: "rusty")
        let old = Constraint(kind: .mustInclude, text: BeatProducer.kitPrefix + "Old Kit")
        let plan = ProducerPlan(style: .trap, kits: ["Amplified Funk Library"], dialValues: ["tempo": 80], note: "")
        let out = BeatProducer.constraints(for: plan, keeping: [mine, old])
        XCTAssertEqual(out.map(\.text), ["rusty", "Style: Trap", "Kit: Amplified Funk Library"])
        let state = WorkingState(goal: "chill beat", domainID: "beats", dials: [], constraints: out)
        XCTAssertEqual(BeatsAdapter.style(for: state).id, "trap")
        let dials = BeatProducer.apply(plan, to: [Dial(name: "Tempo", lowPole: "a", highPole: "b", value: 50),
                                                  Dial(name: "Kit", lowPole: "a", highPole: "b", value: 70)])
        XCTAssertEqual(dials.map(\.value), [80, 0])
    }

    func testKitRequirementMatchesWholeNameNotJustLibrary() {
        let files = kits.flatMap { k in
            [SampleFile(path: "/x/\(k)/Kick.wav", role: .kick, group: k), SampleFile(path: "/x/\(k)/Snare.wav", role: .snare, group: k)]
        }
        let index = SampleIndex(roots: ["/x"], files: files)
        let pick = [Constraint(kind: .mustInclude, text: "Kit: Basement Era Library")]
        for kit in [0.0, 0.5, 0.99] {
            XCTAssertEqual(BeatsAdapter.choose(from: index, goal: "beat", constraints: pick, kit: kit, seed: 1)[.kick]?.group,
                           "Basement Era Library")
        }
        XCTAssertEqual(index.drumKits, kits.sorted())
    }
}

final class ProducerFormatTests: XCTestCase {
    func testFlatAnswersAndNumbersAsTextAreRead() throws {
        let plan = try BeatProducer.parse(#"{"style":"trap","kits":[],"tempo":"72","swing":10,"density":55.5,"note":"ok"}"#, kits: [])
        XCTAssertEqual(plan.style?.id, "trap")
        XCTAssertEqual(plan.dialValues["tempo"], 72)
        XCTAssertEqual(plan.dialValues["swing"], 10)
        XCTAssertEqual(plan.dialValues["density"], 55.5)
        XCTAssertThrowsError(try BeatProducer.parse("sorry, I can't", kits: []))
    }
}

final class BuiltInProducerTests: XCTestCase {
    func testMoodWordsStyleAndKitsComeFromTheGoal() {
        let kits = ["Afrobeats Library", "Basement Era Library", "Dusty Keys Library"]
        let plan = BeatProducer.builtIn(goal: "slow dusty lo-fi with basement era drums", kits: kits)
        XCTAssertEqual(plan.style?.id, "lofi")
        XCTAssertEqual(plan.dialValues["tempo"], 25)
        XCTAssertEqual(plan.dialValues["tone"], 30)
        XCTAssertEqual(plan.dialValues["swing"], 70)
        XCTAssertEqual(plan.kits, ["Basement Era Library", "Dusty Keys Library"])
        XCTAssertEqual(BeatProducer.builtIn(goal: "amapiano groove", kits: kits).kits, ["Afrobeats Library"])
        let plain = BeatProducer.builtIn(goal: "something", kits: kits)
        XCTAssertNil(plain.style)
        XCTAssertTrue(plain.dialValues.isEmpty)
        XCTAssertTrue(plain.kits.isEmpty)
    }
}
