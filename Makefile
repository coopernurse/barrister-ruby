
all:
	ruby -c lib/barrister.rb 
	ruby -c conform/client.rb 
	ruby -c conform/server.rb
	docco lib/barrister.rb
