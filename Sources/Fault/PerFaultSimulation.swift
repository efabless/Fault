import Foundation
import Defile

class PerFaultSimulation: Simulation {
    // Generates pseudorandom test vectors in Verilog. This is generally faster.
    static func pseudoRandomVerilogGeneration(
        for module: String,
        in file: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        at faultPoint: String,
        stuckAt: Int,
        tvAttempts: Int,
        cleanUp: Bool
    ) throws -> [String: UInt]? {

        var portWires = ""
        var portHooks = ""
        var portHooksGM = ""

        for (rawName, port) in ports {
            let name = (rawName.hasPrefix("\\")) ? rawName : "\\\(rawName)"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name).gm ;\n"
            portHooks += ".\(name) ( \(name) ) , "
            portHooksGM += ".\(name) ( \(name).gm ) , "
        }

        let folderName = "thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()

        var finalVector: [String: UInt]? = nil

        var inputAssignment = ""
        var fmtString = ""
        var inputList = ""

        for input in inputs {
            let name = (input.name.hasPrefix("\\")) ? input.name : "\\\(input.name)"

            inputAssignment += "            \(name) = $random(seed) ;\n"
            inputAssignment += "            \(name).gm = \(name) ;\n"

            fmtString += "%d "
            inputList += "\(name) , "
        }

        fmtString = String(fmtString.dropLast(1))
        inputList = String(inputList.dropLast(2))

        var outputComparison = ""
        for output in outputs {
            let name = (output.name.hasPrefix("\\")) ? output.name : "\\\(output.name)"
            outputComparison += " ( \(name) != \(name).gm ) || "
        }
        outputComparison = String(outputComparison.dropLast(3))

        let bench = """
        \(String.boilerplate)

        `include "\(cells)"
        `include "\(file)"

        module FaultTestbench;

        \(portWires)

            \(module) uut(
                \(portHooks.dropLast(2))
            );
            \(module) gm(
                \(portHooksGM.dropLast(2))
            );
            
            initial force uut.\(faultPoint) = \(stuckAt) ;
            integer seed = \(UInt32.random(in: 0...0xFFFFFFFF)) ;

            integer counter;

            initial begin
                for (counter = 0; counter < \(tvAttempts); counter = counter + 1) begin
        \(inputAssignment)
                    if ( \(outputComparison) ) begin
                        $display("\(fmtString)", \(inputList));
                        $finish;
                    end
                    #10;
                end
                $finish;
            end

        endmodule
        """;

        let tbName = "\(folderName)/tb.sv"
        try File.open(tbName, mode: .write) {
            try $0.print(bench)
        }

        let aoutName = "\(folderName)/a.out"

        // Test GM
        let iverilogResult = "iverilog -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
        if iverilogResult != EX_OK {
            exit(Int32(iverilogResult))
        }

        let vvpTask = Process()
        vvpTask.launchPath = "/usr/bin/env"
        vvpTask.arguments = ["sh", "-c", "vvp \(aoutName)"]
        
        let pipe = Pipe()
        vvpTask.standardOutput = pipe

        vvpTask.launch()
        vvpTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let vvpResult = String(String(data: data, encoding: .utf8)!.dropLast(1))

        if vvpTask.terminationStatus != EX_OK {
            exit(vvpTask.terminationStatus)
        }

        let components = vvpResult.components(separatedBy: " ").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if (
            components.count == inputs.count
        ) {
            var vector: [String: UInt] = [:]
            for (i, component) in components.enumerated() {
                vector[inputs[i].name] = UInt(component)!
            }
            finalVector = vector
        }

        let _ = "rm -rf \(folderName)".sh()

        return finalVector
    }

    // Generates pseudorandom test vectors in Swift. This is generally slower, as more testbenches are created.
    static func pseudoRandomSwiftGeneration(
        for module: String,
        in file: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        at faultPoint: String,
        stuckAt: Int,
        tvAttempts: Int,
        cleanUp: Bool
    ) throws -> [String: UInt]? {

        var portWires = ""
        var portHooks = ""

        for (name, port) in ports {
            portWires += "    \(port.polarity == .input ? "reg" : "wire")[\(port.from):\(port.to)] \(name) ;\n"
            portHooks += ".\(name) ( \(name) ) , "
        }

        let folderName = "thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()

        var finalVector: [String: UInt]? = nil

        // in loop?
        for _ in 0..<tvAttempts {
            var inputAssignment = ""

            var vector = [String: UInt]()
            for input in inputs {
                let max: UInt = (1 << UInt(input.width)) - 1
                let num = UInt.random(in: 0...max)
                vector[input.name] = num
                inputAssignment += "        \(input.name) = \(num) ;\n"
            }

            let vcdName = "\(folderName)/dump.vcd";
            let vcdGMName = "\(folderName)/dumpGM.vcd";

            let bench = """
            \(String.boilerplate)

            `include "\(cells)"
            `include "\(file)"

            module FaultTestbench;

            \(portWires)

                \(module) uut(
                    \(portHooks.dropLast(2))
                );
                
                `ifdef FAULT_WITH
                initial force uut.\(faultPoint) = \(stuckAt) ;
                `endif

                initial begin
                    $dumpfile("\(vcdName)");
                    $dumpvars(1, FaultTestbench);
            \(inputAssignment)
                    #100;
                    $finish;
                end

            endmodule
            """;

            let tbName = "\(folderName)/tb.sv"
            try File.open(tbName, mode: .write) {
                try $0.print(bench)
            }

            let aoutName = "\(folderName)/a.out"

            // Test GM
            let iverilogGMResult = "iverilog -Ttyp -o \(aoutName) \(tbName) 2>&1 > /dev/null".sh()
            if iverilogGMResult != EX_OK {
                exit(Int32(iverilogGMResult))
            }
            let vvpGMResult = "vvp \(aoutName) > /dev/null".sh()
            if vvpGMResult != EX_OK {
                exit(Int32(vvpGMResult))
            }

            let _ = "mv '\(vcdName)' '\(vcdGMName)'".sh()

            let iverilogResult = "iverilog -Ttyp -D FAULT_WITH -o \(aoutName) \(tbName) ".sh()
            if iverilogResult != EX_OK {
                exit(Int32(iverilogGMResult))
            }
            let vvpResult = "vvp \(aoutName) > /dev/null".sh()
            if vvpResult != EX_OK {
                exit(Int32(vvpGMResult))
            }

            let difference = "diff \(vcdName) \(vcdGMName) > /dev/null".sh() == 1
            if difference {
                finalVector = vector
                break
            } else {
                //print("Vector \(vector) not viable for \(faultPoint) stuck at \(stuckAt)")
            }
        }

        if cleanUp {
            let _ = "rm -rf \(folderName)".sh()
        }

        return finalVector
    }

    func simulate(
        for faultPoints: Set<String>,
        in file: String,
        module: String,
        with cells: String,
        ports: [String: Port],
        inputs: [Port],
        outputs: [Port],
        tvAttempts: Int,
        sampleRun: Bool
    ) throws -> (json: String, coverage: Float) {
        var promiseDictionary: [String: Future<[String: [String: UInt]?]>] = [:] // We need to go deeper

        for point in faultPoints {
            let currentDictionary = Future<[String: [String: UInt]?]> {
                var currentDictionary: [String: [String: UInt]?] = [:]
                do {
                    currentDictionary["s-a-0"] = try PerFaultSimulation.pseudoRandomVerilogGeneration(for: module, in: file, with: cells, ports: ports, inputs: inputs, outputs: outputs, at: point, stuckAt: 0, tvAttempts: tvAttempts, cleanUp: !sampleRun)
                } catch {
                    print("File I/O failure in \(point) s-a-0")
                }
                do {
                    currentDictionary["s-a-1"] = try PerFaultSimulation.pseudoRandomVerilogGeneration(for: module, in: file, with: cells, ports: ports, inputs: inputs, outputs: outputs, at: point, stuckAt: 1, tvAttempts: tvAttempts, cleanUp: !sampleRun)
                } catch {
                    print("File I/O failure in \(point) s-a-1")
                }
                return currentDictionary
            }
            promiseDictionary[point] = currentDictionary
            if sampleRun {
                break
            }
        }

        var sa0Covered: Float = 0
        var sa1Covered: Float = 0

        var outputDictionary: [String: [String: [String: UInt]?]] = [:]
        for (name, promise) in promiseDictionary {
            let current = promise.value
            if current["s-a-0"]! != nil {
                sa0Covered += 1
            }
            if current["s-a-1"]! != nil {
                sa1Covered += 1
            }
            outputDictionary[name] = current
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(outputDictionary)
        guard let string = String(data: data, encoding: .utf8)
        else {
            throw "Could not create utf8 string."
        }

        return (json: string, coverage: (sa0Covered + sa1Covered) / Float(faultPoints.count * 2))  
    } 
}