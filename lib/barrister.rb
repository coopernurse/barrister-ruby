require "json"
require "net/http"
require "uri"

module Barrister

  def rand_str(len)
    rchars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghiklmnopqrstuvwxyz"
    s = ""
    len.times { s += rchars[rand(rchars.length)] }
    return s
  end
  module_function :rand_str

  class RpcException < StandardError

    attr_accessor :code, :message, :data

    def initialize(code, message, data=nil)
      @code    = code
      @message = message
      @data    = data
    end

  end

  class HttpTransport

    def initialize(url)
      @url = url
      @uri = URI.parse(url)
    end

    def request(req)
      json_str = JSON::generate(req)
      http = Net::HTTP.new(@uri.host, @uri.port)
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

  class Client

    attr_accessor :trans

    def initialize(trans)
      @trans = trans
      load_contract
      init_proxies
    end
   
    def start_batch
      return BatchClient.new(self, @contract)
    end

    def load_contract
      req = { "jsonrpc" => "2.0", "id" => "1", "method" => "barrister-idl" }
      resp = @trans.request(req)
      if resp.key?("result")
        @contract = Contract.new(resp["result"])
      else
        raise RpcException.new(-32000, "Invalid contract response: #{resp}")
      end
    end

    def init_proxies
      singleton = class << self; self end
      @contract.interfaces.each do |iface|
        proxy = InterfaceProxy.new(self, iface)
        singleton.send :define_method, iface.name do
          return proxy
        end
      end
    end

  end

  class RpcResponse

    attr_accessor :id, :result, :error

    def initialize(resp)
      @id     = resp["id"]
      @result = resp["result"]

      if resp["error"]
        e = resp["error"]
        @error = RpcException.new(e["code"], e["message"], e["data"])
      end
    end

  end

  class BatchTransport

    attr_accessor :sent, :requests

    def initialize(client)
      @client   = client
      @requests = [ ]
      @sent     = false
    end

    def request(req)
      if @sent
        raise "Batch has already been sent!"
      end
      @requests << req
      return nil
    end

  end

  class BatchClient < Client

    def initialize(parent, contract)
      @parent   = parent
      @trans    = BatchTransport.new(self)
      @contract = contract
      init_proxies
    end

    def start_batch
      raise "Cannot call start_batch on a batch!"
    end

    def send
      if @trans.sent
        raise "Batch has already been sent!"
      end
      @trans.sent = true

      requests = @trans.requests

      if requests.length < 1
        raise RpcException.new(-32600, "Batch cannot be empty")
      end

      resp_list = @parent.trans.request(requests)
      sorted = [ ]
      by_req_id = { }
      resp_list.each do |resp|
        by_req_id[resp["id"]] = resp
      end

      requests.each do |req|
        id = req["id"]
        resp = by_req_id[id]
        if !resp
          msg = "No result for request id: #{id}"
          resp = { "id" => id, "error" => { "code"=>-32603, "message" => msg } }
        end
        sorted << RpcResponse.new(resp)
      end

      return sorted
    end

  end

  class InterfaceProxy

    def initialize(client, iface)
      singleton = class << self; self end
      iface.functions.each do |f|
        method = iface.name + "." + f.name
        singleton.send :define_method, f.name do |*args|
          req = { "jsonrpc" => "2.0", "id" => Barrister::rand_str(22), "method" => method }
          if args and args.length > 0
            req["params"] = args
          end
          resp = client.trans.request(req)
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

  class Contract

    def initialize(idl)
      @idl = idl
      @interfaces = { }
      @structs    = { }
      @enums      = { }

      idl.each do |item|
        type = item["type"]
        if type == "interface"
          @interfaces[item["name"]] = Interface.new(item)
        end
      end
    end

    def interfaces
      return @interfaces.values
    end

  end

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

  class Function

    attr_accessor :name, :returns, :params
    
    def initialize(f)
      @name    = f["name"]
      @returns = f["returns"]
      @params  = f["params"]
    end

  end

end
