import Foundation
import CoreFoundation // Not automatically imported on Linux
import CommandLineKit
import PythonKit
import Defile
import OrderedDictionary
import BigInt

var env = ProcessInfo.processInfo.environment
let iverilogBase = env["FAULT_IVL_BASE"] ?? "/usr/local/lib/ivl"
let iverilogExecutable = env["FAULT_IVERILOG"] ?? env["PYVERILOG_IVERILOG"] ?? "iverilog"
let vvpExecutable = env["FAULT_VVP"] ?? "vvp"
let yosysExecutable = env["FAULT_YOSYS"] ?? "yosys"

let subcommands: OrderedDictionary =  [
    "synth": (func: synth, desc: "synthesis"),
    "chain": (func: scanChainCreate, desc: "scan chain"),
    "cut": (func: cut, desc: "cutting"),
    "asm": (func: assemble, desc: "test vector assembly"),
    "compact": (func: compactTestVectors, desc: "test vector static compaction"),
    "tap": (func: jtagCreate, desc: "JTAG port"),
    "bench": (func: bench, desc: "verilog netlist to bench format conversion"),
]


func main(arguments: [String]) -> Int32 {
    // MARK: CommandLine Processing
    let cli = CommandLineKit.CommandLine(arguments: arguments)

    let defaultTVCount = "100"
    let defaultTVIncrement = "50"
    let defaultMinimumCoverage = "80"
    let defaultCeiling = "1000"
    let defaultRandGen = "swift"

    let installed = env["FAULT_INSTALL_PATH"] != nil

    let version = BoolOption(
        shortFlag: "V",
        longFlag: "version",
        helpMessage: "Prints the current version and exits."
    )
    if env["FAULT_VER"] != nil {
        cli.addOptions(version)
    }

    let help = BoolOption(
        shortFlag: "h",
        longFlag: "help",
        helpMessage: "Prints this message and exits."
    )
    cli.addOptions(help)

    let filePath = StringOption(
        shortFlag: "o",
        longFlag: "output",
        helpMessage: "Path to the output JSON & SVF files. (Default: input + .tv.json, input + .tv.svf)"
    )
    cli.addOptions(filePath)

    let cellsOption = StringOption(
        shortFlag: "c",
        longFlag: "cellModel",
        helpMessage: ".v file describing the cells \(installed ? "(Default: osu035)" : "(Required.)")"
    )
    cli.addOptions(cellsOption)

    let osu035 = BoolOption(
        longFlag: "osu035",
        helpMessage: "Use the Oklahoma State University standard cell library for -c. (Legacy, now used by default.)"
    )
    if installed {
        cli.addOptions(osu035)
    }

    let testVectorCount = StringOption(
        shortFlag: "v",
        longFlag: "tvCount",
        helpMessage: "Number of test vectors generated (Default: \(defaultTVCount).)"
    )
    cli.addOptions(testVectorCount)

    let testVectorIncrement = StringOption(
        shortFlag: "r",
        longFlag: "increment",
        helpMessage: "Increment in test vector count should sufficient coverage not be reached. (Default: \(defaultTVIncrement).)"
    )
    cli.addOptions(testVectorIncrement)

    let minimumCoverage = StringOption(
        shortFlag: "m",
        longFlag: "minCoverage",
        helpMessage: "Minimum number of fault sites covered percent. Set this to 0 to prevent increments. (Default: \(defaultMinimumCoverage).)"
    )
    cli.addOptions(minimumCoverage)

    let ceiling = StringOption(
        longFlag: "ceiling",
        helpMessage: "Ceiling for Test Vector increments: if this number is reached, no more increments will occur regardless the coverage. (Default: \(defaultCeiling).)"
    )
    cli.addOptions(ceiling)
    
    let tvGen = StringOption(
        shortFlag: "g",
        longFlag: "tvGen",
        helpMessage: "Type of the TV Generator: swift, LFSR, atalanta, and podem. (Default: \(defaultRandGen).)"
    )
    cli.addOptions(tvGen)

    let bench = StringOption(
        shortFlag: "b",
        longFlag: "bench",
        helpMessage: "Netlist in bench format. Required if the TV generator is set to atalanta"
    )
    cli.addOptions(bench)

    let sampleRun = BoolOption(
        longFlag: "sampleRun", 
        helpMessage: "Generate only one testbench for inspection, do not delete it."
    )
    cli.addOptions(sampleRun)

    let ignored = StringOption(
        shortFlag: "i",
        longFlag: "ignoring",
        helpMessage: "Inputs,to,ignore,separated,by,commas. (Default: none)"
    )
    cli.addOptions(ignored)
    
    let clock = StringOption(
        longFlag: "clock",
        helpMessage: "clock name to use for simulation in case of partial scan-chain. (Default: none)"
    )
    cli.addOptions(clock)

    let tvSet = StringOption(
        longFlag: "tvSet",
        helpMessage: ".json file describing an external TV set to be simulated. (Default: TVs are internally generated by one of the TVGen options. )"
    )
    cli.addOptions(tvSet)
    
    let delayModel = BoolOption(
        longFlag: "delay",
        helpMessage: "Runs the transition delay fault simulator."
    )
    cli.addOptions(delayModel)

    do {
        try cli.parse()
    } catch {
        cli.printUsage()
        return EX_USAGE
    }

    if version.value {
        print("Fault \(env["FAULT_VER"]!). ©Cloud V 2019. All rights reserved.")
        return EX_OK
    }

    if help.value {
        cli.printUsage()
        for (key, value) in subcommands {
            print("To take a look at \(value.desc) options, try 'fault \(key) --help'")
        }
        return EX_OK
    }

    let args = cli.unparsedArguments
    if args.count != 1 {
        cli.printUsage()
        return EX_USAGE
    }

    let fileManager = FileManager()
    let file = args[0]
    if !fileManager.fileExists(atPath: file) {
        fputs("File '\(file)' not found.\n", stderr)
        return EX_NOINPUT
    }

    if let modelTest = cellsOption.value {
        if !fileManager.fileExists(atPath: modelTest) {
            fputs("Cell model file '\(modelTest)' not found.\n", stderr)
            return EX_NOINPUT
        }
        if !modelTest.hasSuffix(".v") && !modelTest.hasSuffix(".sv") {
            fputs(
                "Warning: Cell model file provided does not end with .v or .sv.",
                stderr
            )
        }
    }

    let jsonOutput = "\(filePath.value ?? file).tv.json"
    let svfOutput = "\(filePath.value  ?? file).tv.svf"

    let ignoredInputs: Set<String>
        = Set<String>(ignored.value?.components(separatedBy: ",").filter {$0 != ""} ?? [])
    let behavior
        = Array<Simulator.Behavior>(
            repeating: .holdHigh,
            count: ignoredInputs.count
        )

    var cellsFile = cellsOption.value

    if installed {
        if cellsFile == nil {
            cellsFile = env["FAULT_INSTALL_PATH"]! + "/FaultInstall/Tech/osu035/osu035_stdcells.v"
        }
    }

    if osu035.value {
        print("[WARNING] --osu035 flag is deprecated and may be removed in a future vesion.")
    }

    guard let cells = cellsFile else {
        cli.printUsage()
        return EX_USAGE
    }

    // MARK: Importing Python and Pyverilog
    let parse = Python.import("pyverilog.vparser.parser").parse

    // MARK: Parsing and Processing
    let parseResult = parse([file])
    let ast = parseResult[0]
    let description = ast[dynamicMember: "description"]
    var definitionOptional: PythonObject?

    for definition in description.definitions {
        let type = Python.type(definition).__name__
        if type == "ModuleDef" {
            definitionOptional = definition
            break
        }
    }

    guard let definition = definitionOptional else {
        fputs("No module found.\n", stderr)
        return EX_DATAERR
    }

    // MARK: TV generation mode
    var tvSetVectors:[TestVector] = []
    var tvSetInputs: [Port] = []
    if let tvSetTest = tvSet.value {
        if !fileManager.fileExists(atPath: tvSetTest) {
            fputs("TVs json file '\(tvSetTest)' not found.\n", stderr)
            return EX_NOINPUT
        }
        do {
            if tvSetTest.hasSuffix(".json"){
                (tvSetVectors, tvSetInputs) = try TVSet.readFromJson(file: tvSetTest)
            } else {
                (tvSetVectors, tvSetInputs) = try TVSet.readFromText(file: tvSetTest)
            }
        } catch{
            cli.printUsage()
            return EX_USAGE
        }
        print("Read \(tvSetVectors.count) vectors.")
    }

    let tvGenerator: TVGen = TVGen(rawValue: tvGen.value ?? defaultRandGen)!
    let externalGenerator = (tvGenerator == .atalanta || tvGenerator == .podem)
    if let tvGeneratorTest = TVGen(rawValue: tvGen.value ?? defaultRandGen) {
        if externalGenerator {
            if let benchTest = bench.value {
                if !fileManager.fileExists(atPath: benchTest) {
                    fputs("Bench file '\(benchTest)' not found.\n", stderr)
                    return EX_NOINPUT
                }
                if tvGeneratorTest == .atalanta {
                    (tvSetVectors, tvSetInputs) = Atalanta.generate(file: benchTest, module: "\(definition.name)")
                } else {
                    (tvSetVectors, tvSetInputs) = Podem.generate(file: benchTest, module: "\(definition.name)")
                }
                print("Generated \(tvSetVectors.count) test vectors")
                if tvSetVectors.count == 0 {
                    print("[Error]: bench netlist not valid. Are you sure there are no floating nets/outputs ? ")
                    return EX_DATAERR
                }
            } else {
                print("[Error]: bench netlist must be passed to generate TVs with atalanta.\n Run the synthesized netlist through `fault bench` to generate bench netlist. ")
                exit(EX_SOFTWARE)
            }
        }
    }

    guard
        let tvAttempts = Int(testVectorCount.value ?? defaultTVCount),
        let tvIncrement = Int(testVectorIncrement.value ?? defaultTVIncrement),
        let tvMinimumCoverageInt = Int(minimumCoverage.value ?? defaultMinimumCoverage),
        let tvCeiling = Int(ceiling.value ?? (tvSetVectors.count == 0 ? defaultCeiling: String(tvSetVectors.count))),
        let randomGenerator: RNG = (!externalGenerator) ? RNG(rawValue: tvGen.value ?? defaultRandGen) : RNG(rawValue: defaultRandGen)
    else {
        cli.printUsage()
        return EX_USAGE
    }

    let tvMinimumCoverage = Float(tvMinimumCoverageInt) / 100.0

    print("Processing module \(definition.name)…")

    do {
        let (ports, inputs, outputs) = try Port.extract(from: definition)
        
        if inputs.count == 0 {
            print("Module has no inputs.")
            return EX_OK
        }
        if outputs.count == 0 {
            print("Module has no outputs.")
            return EX_OK
        }
       
        // MARK: Discover fault points
        var faultPoints: Set<String> = []
        var gateCount = 0
        var inputsMinusIgnored: [Port] = []
        if tvSetVectors.count == 0 {
            inputsMinusIgnored = inputs.filter {
                !ignoredInputs.contains($0.name)
            }
        } else {
            tvSetInputs.sort { $0.ordinal < $1.ordinal }
            inputsMinusIgnored = tvSetInputs.filter {
                !ignoredInputs.contains($0.name)
            }
        }
        
        for (_, port) in ports {
            if ignoredInputs.contains(port.name) {
                continue
            }
            if port.width == 1 {
                faultPoints.insert(port.name)
            } else {
                let minimum = min(port.from, port.to)
                let maximum = max(port.from, port.to)
                for i in minimum...maximum {
                    faultPoints.insert("\(port.name)[\(i)]")
                }
            }
        }

        var warnAboutDFF = false
        
        for itemDeclaration in definition.items {
            let type = Python.type(itemDeclaration).__name__

            // Process gates
            if type == "InstanceList" {
                gateCount += 1
                let instance = itemDeclaration.instances[0]
                if String(describing: instance.module).starts(with: "DFF") {
                    warnAboutDFF = true
                }
                for hook in instance.portlist {
                    faultPoints.insert("\(instance.name).\(hook.portname)")
                }
            }
        }

        if warnAboutDFF {
            print("Warning: D-flipflops were found in this netlist. Are you sure you ran it through 'fault cut'?")
        }

        print("Found \(faultPoints.count) fault sites in \(gateCount) gates and \(ports.count) ports.")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // MARK: Simulation
        let startTime = CFAbsoluteTimeGetCurrent()

        print("Performing simulations…")

        var coverage: Float
        var data: Data
        if delayModel.value {
            let result = try TFSimulator.simulate(
                for: faultPoints,
                in: args[0],
                module: "\(definition.name)",
                with: cells,
                ports: ports,
                inputs: inputsMinusIgnored,
                ignoring: ignoredInputs,
                behavior: behavior,
                outputs: outputs,
                initialVectorCount: tvAttempts,
                incrementingBy: tvIncrement,
                minimumCoverage: tvMinimumCoverage,
                ceiling: tvCeiling,
                randomGenerator: randomGenerator,
                sampleRun: sampleRun.value,
                using: iverilogExecutable,
                with: vvpExecutable
            )
            coverage = result.coverage
            let tvInfo = TVInfoDelay(inputs: inputsMinusIgnored,
                coverageList: result.coverageList)
            data = try encoder.encode(tvInfo)
        }
        else {
            let result = try Simulator.simulate(
                for: faultPoints,
                in: args[0],
                module: "\(definition.name)",
                with: cells,
                ports: ports,
                inputs: inputsMinusIgnored,
                ignoring: ignoredInputs,
                behavior: behavior,
                outputs: outputs,
                initialVectorCount: tvAttempts,
                incrementingBy: tvIncrement,
                minimumCoverage: tvMinimumCoverage,
                ceiling: tvCeiling,
                randomGenerator: randomGenerator,
                TVSet: tvSetVectors,
                sampleRun: sampleRun.value,
                clock: clock.value,
                using: iverilogExecutable,
                with: vvpExecutable
            )
            coverage = result.coverage
            let tvInfo = TVInfo(inputs: inputsMinusIgnored,
                coverageList: result.coverageList)
            data = try encoder.encode(tvInfo)
        }
        print("Simulations concluded: Coverage \(coverage * 100)%")
        
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("Time elapsed: \(String(format: "%.2f", timeElapsed))s.")
        
        guard let string = String(data: data, encoding: .utf8)
        else {
            throw "Could not create utf8 string."
        }

        try File.open(jsonOutput, mode: .write) {
            try $0.print(string)
        }    
    } catch {
        fputs("Internal error: \(error)", stderr)
        return EX_SOFTWARE
    }

    return EX_OK
}

var arguments = Swift.CommandLine.arguments
if arguments.count >= 2, let subcommand = subcommands[arguments[1]] {
    arguments[0] = "\(arguments[0]) \(arguments[1])"
    arguments.remove(at: 1)
    exit(subcommand.func(arguments))
} else {
    exit(main(arguments: arguments))
}
