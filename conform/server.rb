#!/usr/bin/env ruby

require File.expand_path('../../lib/barrister.rb', __FILE__)
require 'sinatra'

class A
  
  def add(a, b)
    return a+b
  end

  def calc(nums, op)
    total = 0
    if op == "multiply"
      total = 1
    end
    
    nums.each do |n|
      if op == "add"
        total += n
      elsif op == "multiply"
        total = total * n
      else
        raise "Unknown op: #{op}"
      end
    end

    return total
  end

  def sqrt(a)
    Math.sqrt(a)
  end

  def repeat(req)
    resp = { "status" => "ok", "count" => req["count"], "items" => [ ] }
    s = req["to_repeat"]
    if req["force_uppercase"]
      s = s.upcase
    end
    req["count"].times do
      resp["items"] << s
    end
    return resp
  end

  def repeat_num(num, count)
    arr = [ ]
    count.times do
      arr << num
    end
    return arr
  end
  
  def say_hi
    return { "hi" => "hi" }
  end

  def putPerson(person)
    return person["personId"]
  end

end

class B

  def echo(s)
    if s == "return-null"
      return nil
    else
      return s
    end
  end

end

contract = Barrister::contract_from_file("conform.json")
server   = Barrister::Server.new(contract)
server.add_handler("A", A.new)
server.add_handler("B", B.new)

post '/' do
  request.body.rewind
  resp = server.handle_json(request.body.read)
  
  status 200
  headers "Content-Type" => "application/json"
  resp
end
