#!/usr/bin/env ruby

require File.expand_path('../../lib/barrister.rb', __FILE__)

def log_result(out, iface, func, params, resp)
  status = "ok"
  result = -1

  if resp.error
    status = "rpcerr"
    result = resp.error.code
  else
    result = resp.result
  end

  res_json = result
  if res_json.kind_of?(Array) && res_json.kind_of?(Hash)
    res_json = JSON::generate(result)
  else
    # pretty dumb. the built in Ruby JSON::generate won't encode
    # primitives, so we'll wrap in a list, then chop the first and
    # last character off
    res_json = JSON::generate([result], { :ascii_only=>true })
    res_json = res_json.slice(1, res_json.length-2)
  end

  out.write("#{iface}|#{func}|#{params}|#{status}|#{res_json}\n")
end


trans  = Barrister::HttpTransport.new("http://localhost:9233/")
client = Barrister::Client.new(trans)

in_file  = File.open(ARGV[0], "r")
out_file = File.open(ARGV[1], "w")

batch_req = nil
batch = nil

in_file.each do |line|
  line = line.chomp
  next if line == "" or line.start_with?("#")

  if line == "start_batch"
    batch = client.start_batch
    batch_req = [ ]
  elsif line == "end_batch"
    results = batch.send
    for i in (0..(results.length-1))
      res = results[i]
      req = batch_req[i]
      log_result(out_file, req["iface"], req["func"], req["params"], res)
    end
    batch = nil
    batch_req = nil
  else
    cols      = line.split("|")
    iface     = cols[0]
    func      = cols[1]
    params    = cols[2]
    expStatus = cols[3]
    expResult = cols[4]
    
    paramsNative = nil
    if params and params != "null"
      paramsNative = JSON::parse(params)
    end
    method = "#{iface}.#{func}"
    if batch
      batch.request(method, paramsNative)
      batch_req << { "iface" => iface, "func" => func, "params" => params }
    else
      result = client.request(method, paramsNative)
      log_result(out_file, iface, func, params, Barrister::RpcResponse.new({ } , result))
    end
  end

end

in_file.close
out_file.close
