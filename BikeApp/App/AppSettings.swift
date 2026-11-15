import Foundation
import Observation

/// How the app turns virtual gears and slope into trainer commands.
enum ResistanceMode: String, CaseIterable, Identifiable {
    case matchedSimulation
    case ergVirtual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchedSimulation: return "Simulation"
        case .ergVirtual: return "ERG"
        }
    }

    var detail: String {
        switch self {
        case .matchedSimulation:
            return "Der Trainer bekommt Steigung, Rollwiderstand und Luftwiderstand passend zum Gang. Fühlt sich am natürlichsten an."
        case .ergVirtual:
            return "Die App rechnet aus Gang und Trittfrequenz die nötigen Watt und stellt sie per ERG ein. Reagiert etwas träger."
        }
    }
}

/// Persistent user settings, stored in UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    // Rider
    var riderWeight: Double { didSet { defaults.set(riderWeight, forKey: "riderWeight") } }
    var bikeWeight: Double { didSet { defaults.set(bikeWeight, forKey: "bikeWeight") } }
    var ftp: Int { didSet { defaults.set(ftp, forKey: "ftp") } }
    var useIntervalsFTP: Bool { didSet { defaults.set(useIntervalsFTP, forKey: "useIntervalsFTP") } }

    // Trainer and shifting
    var chainring: Int { didSet { defaults.set(chainring, forKey: "chainring") } }
    var cog: Int { didSet { defaults.set(cog, forKey: "cog") } }
    var measuredTrainerRatio: Double { didSet { defaults.set(measuredTrainerRatio, forKey: "measuredTrainerRatio") } }
    var difficulty: Double { didSet { defaults.set(difficulty, forKey: "difficulty") } }
    var resistanceMode: ResistanceMode { didSet { defaults.set(resistanceMode.rawValue, forKey: "resistanceMode") } }
    var startGear: Int { didSet { defaults.set(startGear, forKey: "startGear") } }

    // Display
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") } }
    /// Third row in the bar with Spotify and ride controls.
    var showControlRow: Bool { didSet { defaults.set(showControlRow, forKey: "showControlRow") } }
    var defaultDisplay: DisplayMode { didSet { defaults.set(defaultDisplay.rawValue, forKey: "defaultDisplay") } }

    // Session defaults
    var coursePreset: CoursePreset { didSet { defaults.set(coursePreset.rawValue, forKey: "coursePreset") } }
    var customMinGrade: Double { didSet { defaults.set(customMinGrade, forKey: "customMinGrade") } }
    var customMaxGrade: Double { didSet { defaults.set(customMaxGrade, forKey: "customMaxGrade") } }
    var goalKind: GoalKind { didSet { defaults.set(goalKind.rawValue, forKey: "goalKind") } }
    var goalDistanceKm: Double { didSet { defaults.set(goalDistanceKm, forKey: "goalDistanceKm") } }
    var goalDurationMin: Double { didSet { defaults.set(goalDurationMin, forKey: "goalDurationMin") } }
    var workoutMode: WorkoutMode { didSet { defaults.set(workoutMode.rawValue, forKey: "workoutMode") } }

    // intervals.icu
    var intervalsAthleteId: String { didSet { defaults.set(intervalsAthleteId, forKey: "intervalsAthleteId") } }
    var autoUpload: Bool { didSet { defaults.set(autoUpload, forKey: "autoUpload") } }

    // FTP test
    var ftpTestKind: FTPTestKind { didSet { defaults.set(ftpTestKind.rawValue, forKey: "ftpTestKind") } }
    /// Send a plausible test result to intervals.icu right away.
    var autoTransferFTP: Bool { didSet { defaults.set(autoTransferFTP, forKey: "autoTransferFTP") } }
    /// Test result still to be sent to intervals.icu (0 = none), e.g. because no API key was set.
    var pendingFTPTransfer: Int { didSet { defaults.set(pendingFTPTransfer, forKey: "pendingFTPTransfer") } }

    // Devices: role raw value -> peripheral UUID string
    var assignedDevices: [String: String] { didSet { defaults.set(assignedDevices, forKey: "assignedDevices") } }
    /// Learned Click v2 buttons: "pod:bit" -> "up" / "down". Empty = right half shifts up, left half down.
    var clickButtonMap: [String: String] { didSet { defaults.set(clickButtonMap, forKey: "clickButtonMap") } }

    // Testing without hardware
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        riderWeight = defaults.object(forKey: "riderWeight") as? Double ?? 75
        bikeWeight = defaults.object(forKey: "bikeWeight") as? Double ?? 8
        ftp = defaults.object(forKey: "ftp") as? Int ?? 250
        useIntervalsFTP = defaults.object(forKey: "useIntervalsFTP") as? Bool ?? true
        chainring = defaults.object(forKey: "chainring") as? Int ?? 34
        cog = defaults.object(forKey: "cog") as? Int ?? 14
        measuredTrainerRatio = defaults.object(forKey: "measuredTrainerRatio") as? Double ?? 0
        difficulty = defaults.object(forKey: "difficulty") as? Double ?? 0.5
        resistanceMode = ResistanceMode(rawValue: defaults.string(forKey: "resistanceMode") ?? "") ?? .matchedSimulation
        startGear = defaults.object(forKey: "startGear") as? Int ?? 12
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 0.72
        showControlRow = defaults.object(forKey: "showControlRow") as? Bool ?? true
        defaultDisplay = DisplayMode(rawValue: defaults.string(forKey: "defaultDisplay") ?? "") ?? .bar
        coursePreset = CoursePreset(rawValue: defaults.string(forKey: "coursePreset") ?? "") ?? .hilly
        customMinGrade = defaults.object(forKey: "customMinGrade") as? Double ?? -4
        customMaxGrade = defaults.object(forKey: "customMaxGrade") as? Double ?? 6
        goalKind = GoalKind(rawValue: defaults.string(forKey: "goalKind") ?? "") ?? .distance
        goalDistanceKm = defaults.object(forKey: "goalDistanceKm") as? Double ?? 30
        goalDurationMin = defaults.object(forKey: "goalDurationMin") as? Double ?? 60
        workoutMode = WorkoutMode(rawValue: defaults.string(forKey: "workoutMode") ?? "") ?? .ergOffset
        intervalsAthleteId = defaults.string(forKey: "intervalsAthleteId") ?? "0"
        autoUpload = defaults.object(forKey: "autoUpload") as? Bool ?? true
        ftpTestKind = FTPTestKind(rawValue: defaults.string(forKey: "ftpTestKind") ?? "") ?? .ramp
        autoTransferFTP = defaults.object(forKey: "autoTransferFTP") as? Bool ?? true
        pendingFTPTransfer = defaults.object(forKey: "pendingFTPTransfer") as? Int ?? 0
        assignedDevices = defaults.dictionary(forKey: "assignedDevices") as? [String: String] ?? [:]
        clickButtonMap = defaults.dictionary(forKey: "clickButtonMap") as? [String: String] ?? [:]
        demoMode = defaults.object(forKey: "demoMode") as? Bool ?? false
    }

    var gradeRange: GradeRange {
        coursePreset.range ?? GradeRange(min: min(customMinGrade, customMaxGrade), max: max(customMinGrade, customMaxGrade))
    }

    var rider: RiderParameters {
        RiderParameters(riderMass: riderWeight, bikeMass: bikeWeight)
    }

    /// Gear ratio of the real drivetrain on the trainer (chainring / Zwift Cog), measured if available.
    var trainerRatio: Double {
        if measuredTrainerRatio > 0.5 { return measuredTrainerRatio }
        return Double(max(1, chainring)) / Double(max(1, cog))
    }
}
