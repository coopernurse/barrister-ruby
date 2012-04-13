# **barrister.rb** contains Ruby bindings for Barrister RPC.
#
# The README on the github site has some basic usage examples.
# The Barrister web site has information how to write an IDL file.
#
# For more information, please visit:
#
# * [Barrister main site](http://barrister.bitmechanic.com/)
# * [barrister-ruby on github](https://github.com/coopernurse/barrister-ruby)
#

### Dependencies

# We use [flori's JSON library](http://flori.github.com/json/) which provides
# optional escaping for non-ascii characters.
require "json"

# We use the built in HTTP lib in the default HttpTransport class.
# You can write your own transport class if you want to use another lib
# such as typhoeus.  Transports are designed to be pluggable.
require "net/http"
require "uri"

### Barrister Module

module Barrister
  
  # Reads the given filename and returns a Barrister::Contract
  # object.  The filename should be a Barrister IDL JSON file created with
  # the `barrister` tool.
  def contract_from_file(fname)
    file = File.open(fname, "r")
    contents = file.read
    file.close
    idl = JSON::parse(contents)
    return Contract.new(idl)
  end
  module_function :contract_from_file

  # Helper function to generate IDs for requests.  These IDs only need to
  # be unique within a single request batch, although they may be used for
  # other purposes in the future.  This library will generate a 22 character
  # alpha-numeric ID, which is about 130 bits of entropy.
  def rand_str(len)
    rchars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    s = ""
    len.times do ||
        pos = rand(rchars.length)
        s += rchars[pos,1]
    end
    return s
  end
  module_function :rand_str

  # Helper function that takes a JSON-RPC method string and tokenizes
  # it at the period.  Barrister encodes methods as "interface.function".
  # Returns a two element tuple: interface name, and function name.
  #
  # If no period exists in the method, then we return a nil
  # interface name, and the whole method as the function name.
  def parse_method(method)
    pos  = method.index(".")
    if pos == nil
      return nil, method
    else
      iface_name = method.slice(0, pos)
      func_name  = method.slice(pos+1, method.length)
      return iface_name, func_name
    end
  end
  module_function :parse_method
  
  # Helper function to create a JSON-RPC 2.0 response hash.
  #
  # * `req` - Request hash sent from the client
  # * `result` - Result object from the handler function we called
  #
  # Returns a hash with the `result` slot set, but no `error` slot
  def ok_resp(req, result)
    resp = { "jsonrpc"=>"2.0", "result"=>result }
    if req["id"]
      resp["id"] = req["id"]
    end
    return resp
  end

  # Helper function to create a JSON-RPC 2.0 response error hash.
  #
  # * `req` - Request hash sent from the client
  # * `code` - Integer error code
  # * `message` - String description of the error
  # * `data` - Optional. Additional info about the error. Must be JSON serializable.
  #
  # Returns a hash with the `error` slot set, but no `result`
  def err_resp(req, code, message, data=nil)
    resp = { "jsonrpc"=>"2.0", "error"=> { "code"=>code, "message"=>message } }
    if req["id"]
      resp["id"] = req["id"]
    end
    if data
      resp["error"]["data"] = data
    end

    return resp
  end

  # Represents a JSON-RPC error response.  The Client proxy classes raise this
  # exception if a response is received with an `error` slot.
  #
  # See the [JSON-RPC 2.0 spec](http://jsonrpc.org/specification) for info on
  # built in error codes.  Your code can raise this exception with custom error
  # codes.  Use positive integers as codes to avoid collisions with the built in
  # error codes.
  class RpcException < StandardError

    attr_accessor :code, :message, :data

    def initialize(code, message, data=nil)
      @code    = code
      @message = message
      @data    = data
    end

  end
 
  ### Server

  # The Server class is responsible for taking an incoming request, validating
  # the method and params, invoking the correct handler function (your code), and
  # returning the result.
  #
  # Server has a Barrister::Contract that is initialized in the contructor.
  # It uses the Contract for validation.
  #
  # The Server doesn't do any network communication.  It contains a default
  # `handle_json` convenience method that encapsulates JSON serialization, and a 
  # lower level `handle` method.  This will make it easy to add other serialization
  # formats (such as MessagePack) later.
  #
  class Server
    include Barrister

    # Create a server with the given Barrister::Contract instance
    def initialize(contract)
      @contract = contract
      @handlers = { }
    end

    # Register a handler class with the given interface name
    #
    # The `handler` is any Ruby class that contains methods for each
    # function on the given IDL interface name.
    #
    # These methods will be called when a request is handled by the Server.
    def add_handler(iface_name, handler)
      iface = @contract.interface(iface_name)
      if !iface
        raise "No interface found with name: #{iface_name}"
      end
      @handlers[iface_name] = handler
    end

    # Handles a request encoded as JSON.  
    # Returns the result as a JSON encoded string.
    def handle_json(json_str)
      begin
        req  = JSON::parse(json_str)
        resp = handle(req)
      rescue JSON::ParserError => e
        resp = err_resp({ }, -32700, "Unable to parse JSON: #{e.message}")
      end
      
      # Note the `:ascii_only` usage here. Important.
      return JSON::generate(resp, { :ascii_only=>true })
    end

    # Handles a deserialized request and returns the result
    #
    # `req` must either be a Hash (single request), or an Array (batch request)
    #
    # `handle` returns an Array of results for batch requests, and a single
    # Hash for single requests.
    def handle(req)
      if req.kind_of?(Array)
        resp_list = [ ]
        req.each do |r|
          resp_list << handle_single(r)
        end
        return resp_list
      else
        return handle_single(req)
      end
    end

    # Internal method that validates and executes a single request.
    def handle_single(req)
      method = req["method"]
      if !method
        return err_resp(req, -32600, "No method provided on request")
      end

      # Special case - client is requesting the IDL bound to this server, so
      # we return it verbatim.  No further validation is needed in this case.
      if method == "barrister-idl"
        return ok_resp(req, @contract.idl)
      end

      # Make sure we can find an interface and function on the IDL for this
      # request method string
      err_resp, iface, func = @contract.resolve_method(req)
      if err_resp != nil
        return err_resp
      end
      
      # Make sure that the params on the request match the IDL types
      err_resp = @contract.validate_params(req, func)
      if err_resp != nil
        return err_resp
      end
      
      params = [ ]
      if req["params"]
        params = req["params"]
      end

      # Make sure we have a handler bound to this Server for the interface.
      # If not, that means `server.add_handler` was not called for this interface
      # name.  That's likely a misconfiguration.
      handler = @handlers[iface.name]
      if !handler
        return err_resp(req, -32000, "Server error. No handler is bound to interface #{iface.name}")
      end

      # Make sure that the handler has a method for the given function.
      if !handler.respond_to?(func.name)
        return err_resp(req, -32000, "Server error. Handler for #{iface.name} does not implement #{func.name}")
      end

      begin 
        # Call the handler function. This is where your code gets invoked.
        result  = handler.send(func.name, *params)
        
        # Verify that the handler function's return value matches the
        # correct type as specified in the IDL
        err_resp = @contract.validate_result(req, result, func)
        if err_resp != nil
            return err_resp
        else
          return ok_resp(req, result)
        end
      rescue RpcException => e
        # If the handler raised a RpcException, that's ok - return it unmodified.
        return err_resp(req, e.code, e.message, e.data)
      rescue => e
        # If any other error was raised, print it and return a generic error to the client
        puts e.inspect
        puts e.backtrace
        return err_resp(req, -32000, "Unknown error: #{e}")
      end
    end

  end
  
  ### Client

  # This is the main class used when writing a client for a Barrister service.
  #
  # Clients accept a transport class on the constructor which encapsulates 
  # serialization and network communciation.  Currently this module only provides a 
  # basic HTTP transport, but other transports can be easily written.
  class Client
    include Barrister

    attr_accessor :trans

    # Create a new Client.  This immediately makes a `barrister-idl` request to fetch
    # the IDL from the Server.  A Barrister::Contract is created from this IDL and used
    # to expose proxy objects for each interface on the IDL.
    #
    # * `trans` - Transport instance to use. Must have a `request(req)` method
    # * `validate_req` - If true, request parameters will be validated against the IDL
    #                    before sending the request to the transport.
    # * `validate_result` - If true, the result from the server will be validated against the IDL
    #
    def initialize(trans, validate_req=true, validate_result=true)
      @trans           = trans
      @validate_req    = validate_req
      @validate_result = validate_result

      load_contract
      init_proxies
    end

    # Returns the hash of metadata from the Contract, which includes the date the
    # IDL was translated to JSON, the Barrister version used to translate the IDL, and
    # a checksum of the IDL which can be used to detect version changes.
    def get_meta
      return @contract.meta
    end
   
    # Returns a Barrister::BatchClient instance that is associated with this Client instance
    #
    # Batches let you send multiple requests in a single round trip
    def start_batch
      return BatchClient.new(self, @contract)
    end

    # Internal method invoked by `initialize`.  Sends a `barrister-idl` request to the
    # server and creates a Barrister::Contract with the result.
    def load_contract
      req = { "jsonrpc" => "2.0", "id" => "1", "method" => "barrister-idl" }
      resp = @trans.request(req)
      if resp.key?("result")
        @contract = Contract.new(resp["result"])
      else
        raise RpcException.new(-32000, "Invalid contract response: #{resp}")
      end
    end

    # Internal method invoked by `initialize`.  Iterates through the Contract and
    # creates proxy classes for each interface.
    def init_proxies
      singleton = class << self; self end
      @contract.interfaces.each do |iface|
        proxy = InterfaceProxy.new(self, iface)
        singleton.send :define_method, iface.name do
          return proxy
        end
      end
    end

    # Sends a JSON-RPC request.  This method is automatically called by the proxy classes, 
    # so in practice you don't usually call it directly.  However, it is available if you
    # wish to avoid the use of proxy classes.
    #
    # * `method` - string of the method to invoke. Format: "interface.function".
    #              For example: "ContactService.saveContact"
    # * `params` - parameters to pass to the function. Must be an Array
    def request(method, params)
      req = { "jsonrpc" => "2.0", "id" => Barrister::rand_str(22), "method" => method }
      if params
        req["params"] = params
      end
      
      # We always validate that the method is valid
      err_resp, iface, func = @contract.resolve_method(req)
      if err_resp != nil
        return err_resp
      end
        
      if @validate_req
        err_resp = @contract.validate_params(req, func)
        if err_resp != nil
          return err_resp
        end
      end
      
      # This makes the request to the server
      resp = @trans.request(req)
      
      if @validate_result && resp != nil && resp.key?("result")
        err_resp = @contract.validate_result(req, resp["result"], func)
        if err_resp != nil
          resp = err_resp
        end
      end
      
      return resp
    end

  end

  # Default HTTP transport implementation.  This is a simple implementation that
  # doesn't support many options.  We may extend this class in the future, but 
  # you can always write your own transport class based on this one.
  class HttpTransport

    # Takes the URL to the server endpoint and parses it
    def initialize(url)
      @url = url
      @uri = URI.parse(url)
    end

    # `request` is the only required method on a transport class.  
    #
    # `req` is a JSON-RPC request with `id`, `method`, and optionally `params` slots.
    #
    # The transport is very simple, and does the following:
    #
    # * Serialize `req` to JSON. Make sure to use `:ascii_only=true`
    # * POST the JSON string to the endpoint, setting the MIME type correctly
    # * Deserialize the JSON response string
    # * Return the deserialized hash
    #
    def request(req)
      json_str = JSON::generate(req, { :ascii_only=>true })
      http    = Net::HTTP.new(@uri.host, @uri.port)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request.body = json_str
      request["Content-Type"] = "application/json"
      response = http.request(request)
      if response.code != "200"
        raise RpcException.new(-32000, "Non-200 response #{response.code} from #{@url}")
      else
        return JSON::parse(response.body)
      end
    end

  end

  # Represents as single JSON-RPC response.  This is used by the Batch class
  # so that responses are wrapped in a more friendly class container.
  #
  # Non-batch calls don't need this wrapper, as they receive the result directly,
  # or have a RpcException raised.
  class RpcResponse

    # Properties exposed on the response
    #
    # You can raise `resp.error` when you iterate through
    # results from a batch send.
    attr_accessor :id, :method, :params, :result, :error

    def initialize(req, resp)
      @id     = resp["id"]
      @result = resp["result"]
      @method = req["method"]
      @params = req["params"]

      if resp["error"]
        e = resp["error"]
        @error = RpcException.new(e["code"], e["message"], e["data"])
      end
    end

  end

  # Internal transport used by the BatchClient.  You shouldn't create this
  # directly.
  class BatchTransport

    attr_accessor :sent, :requests

    def initialize(client)
      @client   = client
      @requests = [ ]
      @sent     = false
    end

    # Request simply stores the req object in an interal Array
    # When send() is called on the BatchClient, these are sent to the server.
    def request(req)
      if @sent
        raise "Batch has already been sent!"
      end
      @requests << req
      return nil
    end

  end

  # BatchClient acts like a Client and exposes the same proxy classes
  # as a normal Client instance.  However, none of the proxy function calls
  # return values.  Instead, they are stored in an Array until `batch.send()`
  # is called.
  #
  # Use a batch if you have many small requests that you'd like to send at once.
  #
  # **Note:** the JSON-RPC spec indicates that servers **may** execute batch
  # requests in parallel.  Do **not** batch requests that depend on being 
  # sequentially executed.
  class BatchClient < Client

    # * `parent` - the Client instance we were created from
    # * `contract` - The contract associated with this Client. Used to init proxies.
    def initialize(parent, contract)
      @parent   = parent
      @trans    = BatchTransport.new(self)
      @contract = contract
      init_proxies
    end

    # Overrides start_batch and blows up if called
    def start_batch
      raise "Cannot call start_batch on a batch!"
    end

    # Sends the batch of requests to the server.
    #
    # Returns an Array of RpcResponse instances.  The Array is ordered
    # in the order of the requests made to the batch.  Your code needs
    # to check each element in the Array for errors.
    #
    # * Cannot be called more than once
    # * Will raise RpcException if the batch is empty
    def send
      if @trans.sent
        raise "Batch has already been sent!"
      end
      @trans.sent = true

      requests = @trans.requests

      if requests.length < 1
        raise RpcException.new(-32600, "Batch cannot be empty")
      end

      # Send request batch to server
      resp_list = @parent.trans.request(requests)
      
      # Build a hash for the responses so we can re-order them
      # in request order.
      sorted    = [ ]
      by_req_id = { }
      resp_list.each do |resp|
        by_req_id[resp["id"]] = resp
      end

      # Iterate through the requests in the batch and assemble
      # the sorted result array
      requests.each do |req|
        id = req["id"]
        resp = by_req_id[id]
        if !resp
          msg = "No result for request id: #{id}"
          resp = { "id" => id, "error" => { "code"=>-32603, "message" => msg } }
        end
        sorted << RpcResponse.new(req, resp)
      end

      return sorted
    end

  end

  # Internal class used by the Client and BatchClient classes
  # 
  # Each instance represents a proxy for a single interface in the IDL,
  # and will contain a method for each function in the interface.
  #
  # These proxy methods call `Client.request` when invoked
  #
  class InterfaceProxy

    def initialize(client, iface)
      singleton = class << self; self end
      iface.functions.each do |f|
        method = iface.name + "." + f.name
        singleton.send :define_method, f.name do |*args|
          resp = client.request(method, args)
          if client.trans.instance_of? BatchTransport
            return nil
          else
            if resp.key?("result")
              return resp["result"]
            else
              err = resp["error"]
              raise RpcException.new(err["code"], err["message"], err["data"])
            end
          end
        end
      end
    end

  end

  ### Contract / IDL
  
  # Represents a single parsed IDL definition
  class Contract
    include Barrister

    attr_accessor :idl, :meta

    # `idl` must be an Array loaded from a Barrister IDL JSON file
    #
    # `initialize` iterates through the IDL and stores the 
    # interfaces, structs, and enums specified in the IDL
    def initialize(idl)
      @idl = idl
      @interfaces = { }
      @structs    = { }
      @enums      = { }
      @meta       = { }

      idl.each do |item|
        type = item["type"]
        if type == "interface"
          @interfaces[item["name"]] = Interface.new(item)
        elsif type == "struct"
          @structs[item["name"]] = item
        elsif type == "enum"
          @enums[item["name"]] = item
        elsif type == "meta"
          item.keys.each do |key|
            if key != "type"
              @meta[key] = item[key]
            end
          end
        end
      end
    end

    # Returns the Interface instance for the given name
    def interface(name)
      return @interfaces[name]
    end

    # Returns all Interfaces defined on this Contract
    def interfaces
      return @interfaces.values
    end
    
    # Takes a JSON-RPC request hash, and returns a 3 element tuple. This is called as
    # part of the request validation sequence.
    #
    # `0` - JSON-RPC response hash representing an error. nil if valid.
    # `1` - Interface instance on this Contract that matches `req["method"]`
    # `2` - Function instance on the Interface that matches `req["method"]`
    def resolve_method(req)
      method = req["method"]
      iface_name, func_name = Barrister::parse_method(method)
      if iface_name == nil
        return err_resp(req, -32601, "Method not found: #{method}")
      end
      
      iface = interface(iface_name)
      if !iface
        return err_resp(req, -32601, "Interface not found on IDL: #{iface_name}")
      end

      func = iface.function(func_name)
      if !func
        return err_resp(req, -32601, "Function #{func_name} does not exist on interface #{iface_name}")
      end
      
      return nil, iface, func
    end
    
    # Validates that the parameters on the JSON-RPC request match the types specified for
    # this function
    #
    # Returns a JSON-RPC response hash if invalid, or nil if valid.
    #
    # * `req` - JSON-RPC request hash
    # * `func` - Barrister::Function instance
    #
    def validate_params(req, func)
      params = req["params"]
      if !params
        params = []
      end
      e_params  = func.params.length
      r_params  = params.length
      if e_params != r_params
        msg = "Function #{func.name}: Param length #{r_params} != expected length: #{e_params}"
        return err_resp(req, -32602, msg)
      end

      for i in (0..(e_params-1))
        expected = func.params[i]
        invalid = validate("Param[#{i}]", expected, expected["is_array"], params[i])
        if invalid != nil
          return err_resp(req, -32602, invalid)
        end
      end

      # valid
      return nil
    end
    
    # Validates that the result from a handler method invocation match the return type
    # for this function
    #
    # Returns a JSON-RPC response hash if invalid, or nil if valid.
    #
    # * `req` - JSON-RPC request hash
    # * `result` - Result object from the handler method call
    # * `func` - Barrister::Function instance
    #
    def validate_result(req, result, func)
      invalid = validate("", func.returns, func.returns["is_array"], result)
      if invalid == nil
        return nil
      else
        return err_resp(req, -32001, invalid)
      end
    end

    # Validates the type for a single value. This method is recursive when validating
    # arrays or structs.
    #
    # Returns a string describing the validation error if invalid, or nil if valid
    #
    # * `name` - string to prefix onto the validation error
    # * `expected` - expected type (hash)
    # * `expect_array` - if true, we expect val to be an Array
    # * `val` - value to validate
    #
    def validate(name, expected, expect_array, val)
      # If val is nil, then check if the IDL allows this type to be optional
      if val == nil
        if expected["optional"]
          return nil
        else
          return "#{name} cannot be null"
        end
      else
        exp_type = expected["type"]

        # If we expect an array, make sure that val is an Array, and then
        # recursively validate the elements in the array
        if expect_array
          if val.kind_of?(Array)
            stop = val.length - 1
            for i in (0..stop)
              invalid = validate("#{name}[#{i}]", expected, false, val[i])
              if invalid != nil
                return invalid
              end
            end

            return nil
          else
            return type_err(name, "[]"+expected["type"], val)
          end
          
        # Check the built in Barrister primitive types
        elsif exp_type == "string"
          if val.class == String
            return nil
          else
            return type_err(name, exp_type, val)
          end
        elsif exp_type == "bool"
          if val.class == TrueClass || val.class == FalseClass
            return nil
          else
            return type_err(name, exp_type, val)
          end
        elsif exp_type == "int" || exp_type == "float"
          if val.class == Integer || val.class == Fixnum || val.class == Bignum
            return nil
          elsif val.class == Float && exp_type == "float"
            return nil
          else
            return type_err(name, exp_type, val)
          end
          
        # Expected type is not an array or a Barrister primitive.
        # It must be a struct or an enum.
        else
          
          # Try to find a struct
          struct = @structs[exp_type]
          if struct
            if !val.kind_of?(Hash)
              return "#{name} #{exp_type} value must be a map/hash. not: " + val.class.name
            end
            
            s_field_keys = { }
            
            # Resolve all fields on the struct and its ancestors
            s_fields = all_struct_fields([], struct)
            
            # Validate that each field on the struct has a valid value
            s_fields.each do |f|
              fname = f["name"]
              invalid = validate("#{name}.#{fname}", f, f["is_array"], val[fname])
              if invalid != nil
                return invalid
              end
              s_field_keys[fname] = 1
            end
            
            # Validate that there are no extraneous elements on the value
            val.keys.each do |k|
              if !s_field_keys.key?(k)
                return "#{name}.#{k} is not a field in struct '#{exp_type}'"
              end
            end
            
            # Struct is valid
            return nil
          end

          # Try to find an enum
          enum = @enums[exp_type]
          if enum
            if val.class != String
              return "#{name} enum value must be a string. got: " + val.class.name
            end

            # Try to find an enum value that matches this val
            enum["values"].each do |en|
              if en["value"] == val
                return nil
              end
            end

            # Invalid
            return "#{name} #{val} is not a value in enum '#{exp_type}'"
          end

          # Unlikely branch - suggests the IDL is internally inconsistent
          return "#{name} unknown type: #{exp_type}"
        end

        # Panic if we have a branch unaccounted for. Indicates a Barrister bug.
        raise "Barrister ERROR: validate did not return for: #{name} #{expected}"
      end
    end

    # Recursively resolves all fields for the struct and its ancestors
    #
    # Returns an Array with all the fields
    def all_struct_fields(arr, struct)
      struct["fields"].each do |f|
        arr << f
      end

      if struct["extends"]
        parent = @structs[struct["extends"]]
        if parent
          return all_struct_fields(arr, parent)
        end
      end

      return arr
    end

    # Helper function that returns a formatted string for a type mismatch error
    def type_err(name, exp_type, val)
      actual = val.class.name
      return "#{name} expects type '#{exp_type}' but got type '#{actual}'"
    end

  end

  # Represents a Barrister IDL "interface" 
  class Interface

    attr_accessor :name

    def initialize(iface)
      @name = iface["name"]
      @functions = { }
      iface["functions"].each do |f|
        @functions[f["name"]] = Function.new(f)
      end
    end

    def functions
      return @functions.values
    end

    def function(name)
      return @functions[name]
    end
    
  end

  # Represents a single function on a Barrister IDL "interface" 
  class Function

    attr_accessor :name, :returns, :params
    
    def initialize(f)
      @name    = f["name"]
      @returns = f["returns"]
      @params  = f["params"]
    end

  end

end
