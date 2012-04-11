
# Barrister for Ruby

This project contains Ruby bindings for the Barrister RPC system.

## Installation

Install the package:

    gem install barrister
    
If you are writing a server, you will also need the main `barrister` command
line tool to convert your IDL files to JSON.  It's written in Python, and can
be installed via:

    pip install barrister
    
See [the docs](http://barrister.bitmechanic.com/docs.html) for more information on the
`barrister` tool and IDL format.

## Basic Usage

**Client**

    require 'barrister'

    # specify URL to the server endpoint
    trans = Barrister::HttpTransport.new("http://localhost:7667/calc")

    # automatically connects to endpoint and loads IDL JSON contract
    # also creates proxy classes on client - one per interface in the IDL
    client = Barrister::Client.new(trans)

    # make a RPC call
    #
    # in this example the server exposes a "Calculator" interface 
    # that contains a "add" method.
    #
    puts client.Calculator.add(1, 5.1)

    
**Server**

Note, there's no requirement to use Sinatra. Any web framework that provides 
access to the raw POST data is probably fair game.

Given this IDL:

    // file: calc.idl
    interface Calculator {
        add(a float, b float) float
        subtract(a float, b float) float
    }
    
That you translate via:

    barrister -t "Calculator Service" -j calc.json calc.idl

Then you could write this server:

    require 'sinatra'
    require 'barrister'
    
    # Define a class that implements the functions in the interface
    class Calculator
    
      def add(a, b)
        return a+b
      end
    
      def subtract(a, b)
        return a-b
      end
    
    end
    
    # Load the IDL JSON file and create a Server instance
    contract = Barrister::contract_from_file("calc.json")
    server   = Barrister::Server.new(contract)
    
    # Bind your class to the Calculator interface
    # If your IDL has multiple interfaces, you would bind
    # them all to the same server instance.
    server.add_handler("Calculator", Calculator.new)
    
    # Serve it up
    post '/calc' do
      request.body.rewind
      resp = server.handle_json(request.body.read)
      
      status 200
      headers "Content-Type" => "application/json"
      resp
    end
    

## Compatibility

Developed on MacOS with Ruby 1.9.3.  CI tests run on Linux against Ruby 1.8.7.  

Depends on the `json` gem.

## More information

* [Annotated source](http://barrister.bitmechanic.com/api/ruby/latest/barrister.html)
* [Barrister site](http://barrister.bitmechanic.com/) - Includes examples
* [IDL docs](http://barrister.bitmechanic.com/docs.html) - How to write an IDL and convert to JSON
