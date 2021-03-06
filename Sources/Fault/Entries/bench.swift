import Foundation
import CoreFoundation
import CommandLineKit
import PythonKit
import Defile

func bench(arguments: [String]) -> Int32 {
    // MARK: CommandLine Processing
    let cli = CommandLineKit.CommandLine(arguments: arguments)

    let help = BoolOption(
        shortFlag: "h",
        longFlag: "help",
        helpMessage: "Prints this message and exits."
    )
    cli.addOptions(help)

    let cellsOption = StringOption(
        shortFlag: "c",
        longFlag: "cellModel",
        helpMessage: "Path to cell models file. (.v) files are converted to (.json). If .json is available, it could be supplied directly."
    )
    cli.addOptions(cellsOption)

    let filePath = StringOption(
        shortFlag: "o",
        longFlag: "output",
        helpMessage: "Path to the output file. (Default: input + .bench)"
    )
    cli.addOptions(filePath)

    do {
        try cli.parse()
    } catch {
        Stderr.print(error)
        Stderr.print("Invoke fault bench --help for more info.")
        return EX_USAGE
    }

    if help.value {
        cli.printUsage()
        return EX_OK
    }

    let args = cli.unparsedArguments
    if args.count != 1 {
        Stderr.print("Invalid argument count: (\(args.count)/\(1))")
        Stderr.print("Invoke fault bench --help for more info.")
        return EX_USAGE
    }

    let fileManager = FileManager()
    let file = args[0]
    if !fileManager.fileExists(atPath: file) {
        Stderr.print("File '\(file)' not found.")
        return EX_NOINPUT
    }
    
    let output = filePath.value ?? "\(file).bench"

    guard let cellModel = cellsOption.value else {
        Stderr.print("Option --cellModel is required.")
        Stderr.print("Invoke fault bench --help for more info.")
        return EX_USAGE
    }

    if !fileManager.fileExists(atPath: cellModel) {
        Stderr.print("Cell model file '\(cellModel)' not found.")
        return EX_NOINPUT
    }

    var cellModelsFile = cellModel

    if cellModel.hasSuffix(".v") || cellModel.hasSuffix(".sv") {
        print("Creating json for the cell models…")
        cellModelsFile = "\(cellModel).json"

        let cellModels =
        "grep -E -- \"\\bmodule\\b|\\bendmodule\\b|and|xor|or|not(\\s+|\\()|buf|input.*;|output.*;\" \(cellModel)".shOutput();
        let pattern = "(?s)(?:module).*?(?:endmodule)"

        var cellDefinitions = ""
        if let range = cellModels.output.range(of: pattern, options: .regularExpression) {
            cellDefinitions = String(cellModels.output[range])
        }
        do {

        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(cellModels.output.startIndex..., in: cellModels.output)
        let results = regex.matches(in: cellModels.output, range: range)   
        let matches = results.map { String(cellModels.output[Range($0.range, in: cellModels.output)!])}     
        
        cellDefinitions = matches.joined(separator: "\n")

        let folderName = "\(NSTemporaryDirectory())/thr\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        let _ = "mkdir -p \(folderName)".sh()
        
        defer {
            let _ = "rm -rf \(folderName)".sh()
        }
        let CellFile = "\(folderName)/cells.v"
    
        try File.open(CellFile, mode: .write) {
            try $0.print(cellDefinitions)
        }

        // MARK: Importing Python and Pyverilog
        let parse = Python.import("pyverilog.vparser.parser").parse

        // MARK: Parse
        let ast = parse([CellFile])[0]
        let description = ast[dynamicMember: "description"]

        let cells = try BenchCircuit.extract(definitions: description.definitions)
        let circuit = BenchCircuit(cells: cells)
        let encoder = JSONEncoder()
        
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(circuit)

        guard let string = String(data: data, encoding: .utf8) else {
            throw "Could not create utf8 string."
        }

        try File.open(cellModelsFile, mode: .write) {
            try $0.print(string)
        }

        } catch {
            Stderr.print("Internal error: \(error)")
            return EX_SOFTWARE
        }
    }
    else if !cellModel.hasSuffix(".json") {
        Stderr.print(
            "Warning: Cell model file provided does not end with .v or .sv or .json."
        )
        Stderr.print(
            "It will be treated as a json file."
        )
    }
    do {
        // MARK: Processing Library Cells
        let data = try Data(contentsOf: URL(fileURLWithPath: cellModelsFile), options: .mappedIfSafe)
        guard let benchCells = try? JSONDecoder().decode(BenchCircuit.self, from: data) else {
            Stderr.print("File '\(cellsOption.value!)' is invalid.")
            return EX_DATAERR
        }

        let cellsDict = benchCells.cells.reduce(into: [String: BenchCell]()) {
            $0[$1.name] = $1
        }

        // MARK: Importing Python and Pyverilog
        let parse = Python.import("pyverilog.vparser.parser").parse

        // MARK: Parse
        let ast = parse([file])[0]
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
            Stderr.print("No module found.")
            exit(EX_DATAERR)
        }

        let (_, inputs, outputs) = try Port.extract(from: definition)

        var inputNames: [String] = []
        var usedInputs: [String] = []
        var floatingOutputs: [String] = []
        var benchStatements: String = ""
        for input in inputs {
            if input.width > 1 {
                let range = (input.from > input.to) ? input.to...input.from : input.from...input.to
                for index in range {
                    let name = "\(input.name)[\(index)]"
                    inputNames.append(name)
                    benchStatements += "INPUT(\(name)) \n"
                }
            }
            else {
                let name = input.name
                inputNames.append(name)
                benchStatements += "INPUT(\(name)) \n"
            }
        }

        for item in definition.items {
            
            let type = Python.type(item).__name__
            // Process gates
            if type == "InstanceList" {
                let instance = item.instances[0]
                let cellName =  String(describing: instance.module)
                let instanceName = String(describing: instance.name)
                let cell = cellsDict[cellName]!

                var inputs: [String:String] = [:]
                var outputs: [String] = []
                for hook in instance.portlist {
                    let portname = String(describing: hook.portname)
                    let type =  Python.type(hook.argname).__name__
            
                    if  portname == cell.output {
                        if type == "Pointer" {
                            outputs.append("\(hook.argname.var)[\(hook.argname.ptr)]")
                        } else {
                            outputs.append(String(describing: hook.argname))
                        }
                    }
                    else {
                        if type == "Pointer" {
                            inputs[portname] = "\(hook.argname.var)[\(hook.argname.ptr)]"
                        } else {
                            inputs[portname] = String(describing: hook.argname)
                        }
                    }
                }
                
                let statements = try cell.extract(name: instanceName, inputs: inputs, output: outputs)
                benchStatements += "\(statements) \n" 
                
                usedInputs.append(contentsOf: Array(inputs.values))
            }
            else if type == "Assign"{

                var right = ""
                if Python.type(item.right.var).__name__ == "Pointer" {
                    right = "\(item.right.var.var)[\(item.right.var.ptr)]"
                } else {
                    right = "\(item.right.var)"
                }
                
                var left = ""
                if Python.type(item.left.var).__name__ == "Pointer" {
                    left = "\(item.left.var.var)[\(item.left.var.ptr)]"
                } else {
                    left = "\(item.left.var)"
                }

                if right == "1'b0" || right == "1'h0" {
                    print("[Warning]: Constants are not recognized by atalanta. Removing \(left) associated gates and nets..")
                    floatingOutputs.append(left)
                } else {
                    let statement = "\(left) = BUFF(\(right)) \n"
                    benchStatements += statement

                    usedInputs.append(right)
                }
                    
            }
        }
        let ignoredInputs = inputNames.filter { !usedInputs.contains($0) }
        print("Found \(ignoredInputs.count) floating inputs.")

        let filteredOutputs = outputs.filter { !floatingOutputs.contains($0.name) }
        for output in filteredOutputs {
            if output.width > 1 {
                let range = (output.from > output.to) ? output.to...output.from : output.from...output.to
                for index in range {
                    benchStatements += "OUTPUT(\(output.name)[\(index)]) \n"
                }
            }
            else {
                benchStatements += "OUTPUT(\(output.name)) \n"
            }
        }

        var floatingStatements = ""
        for input in ignoredInputs {
            floatingStatements += "OUTPUT(\(input)) \n"            
        }

        let boilerplate = """
        #    Bench for \(definition.name)
        #    Automatically generated by Fault.
        #    Don't modify. \n
        """
        try File.open(output, mode: .write) {
            try $0.print(boilerplate)
            try $0.print(floatingStatements.dropLast())
            try $0.print(benchStatements)
        }

    } catch {
        Stderr.print("Internal error: \(error)")
        return EX_SOFTWARE
    }
    
    return EX_OK
}