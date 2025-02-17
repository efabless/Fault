import PythonKit
import Foundation

class Port: Codable {
    enum Polarity: String, Codable {
        case input
        case output
        case unknown
    }
    var name: String
    var polarity: Polarity?
    var from: Int
    var to: Int
    var ordinal: Int

    var width: Int {
        return from < to ? to - from + 1 : from - to + 1
    }

    init(name: String, at ordinal: Int) {
        self.name = name
        self.from = 0
        self.to = 0
        self.ordinal = ordinal
    }

    static func extract(from definition: PythonObject) throws -> (ports: [String: Port], inputs: [Port], outputs: [Port]) {
        var ports: [String: Port] = [:]
        var inputs: [Port] = []
        var outputs: [Port] = []
        var paramaters: [String: Int] = [:]
        for (i, portDeclaration) in definition.portlist.ports.enumerated() {
            let port = Port(name: "\(portDeclaration.name)", at: i)
            ports["\(portDeclaration.name)"] = port
        }
        
        for itemDeclaration in definition.items {
            let type = Python.type(itemDeclaration).__name__
            // Process port declarations further
            if type == "Decl" {
                let declaration = itemDeclaration.list[0]
                let declType = Python.type(declaration).__name__
                if declType == "Parameter" {
                    paramaters["\(declaration.name)"] = 
                        Port.evaluate(expr: declaration.value.var, params: paramaters)
                } else if declType == "Input" || declType == "Output" {
                    guard let port = ports["\(declaration.name)"] else {
                        throw "Unknown port \(declaration.name)"
                    }
                    if declaration.width != Python.None {
                        let msb = Port.evaluate(expr: declaration.width.msb, params: paramaters) 
                        let lsb = Port.evaluate(expr: declaration.width.lsb, params: paramaters) 
                        port.from = msb
                        port.to = lsb
                    }
                    if declType == "Input" {
                        port.polarity = .input
                        inputs.append(port)
                    } else {
                        port.polarity = .output
                        outputs.append(port)
                    }
                }
            }
        }

        inputs.sort { $0.ordinal < $1.ordinal }
        outputs.sort { $0.ordinal < $1.ordinal }

        return (ports: ports, inputs: inputs, outputs: outputs)
    }

    private static func evaluate(expr: PythonObject, params: [String: Int]) -> Int {
        let type = "\((Python.type(expr)).__name__)"
        var value = 0
        switch type {
        case "Minus",
             "Plus",
             "Sll":
            let left = Port.evaluate(expr: expr.left, params: params)
            let right = Port.evaluate(expr: expr.right, params: params)
            value = Port.op[type]!(left, right)
            break
        case "IntConst":
            value = Int("\(expr.value)")!
            break
        case "Identifier":
            value = params["\(expr.name)"]!
            break
        default:
            print("Got unknow expression type \(type)");
            exit(EX_DATAERR)
        }    
        return value
    }

    static let op = [
        "Minus": sub,
        "Plus": add,
        "Sll": sll
    ]
}

extension Port: CustomStringConvertible {
    var description: String {
        return "Port(\(name): \(polarity ?? .unknown)[\(from)..\(to)])"
    }
}

func add (left: Int, right: Int) -> Int {
    return left + right
}
func sub (left: Int, right: Int) -> Int {
    return left - right 
}
func sll(left: Int ,right: Int) -> Int {
    return left << right
}