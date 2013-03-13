require 'spec_helper'

def wait
  sleep 0.3 # FIXME: hack
end

describe Instrumental::Agent, "disabled" do
  before do
    Instrumental::Agent.logger.level = Logger::UNKNOWN
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :reporting_interval => 0.1, :collector => @server.url, :enabled => false)
  end

  after do
    @agent.stop
    @agent = nil
    @server.stop
  end

  it "should not connect to the server" do
    wait
    @server.connect_count.should == 0
  end

  it "should not connect to the server after receiving a metric" do
    wait
    @agent.gauge('disabled_test', 1)
    wait
    @server.connect_count.should == 0
  end

  it "should no op on flush without reconnect" do
    1.upto(100) { @agent.gauge('disabled_test', 1) }
    @agent.flush(:allow_reconnect => false)
    wait
    @server.commands.should be_empty
  end

  it "should no op on flush with reconnect" do
    1.upto(100) { @agent.gauge('disabled_test', 1) }
    @agent.flush(:allow_reconnect => true)
    wait
    @server.commands.should be_empty
  end

  it "should no op on an empty flush" do
    @agent.flush(:allow_reconnect => true)
    wait
    @server.commands.should be_empty
  end
end

describe Instrumental::Agent, "enabled" do
  before do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :reporting_interval => 0.1, :collector => @server.url, :synchronous => false)
  end

  after do
    @agent.stop
    @agent = nil
    @server.stop
  end

  it "should not connect to the server" do
    wait
    @server.connect_count.should == 0
  end

  it "should connect to the server after sending a metric" do
    @agent.increment("test.foo")
    wait
    @server.connect_count.should == 1
  end

  it "should send authentication, user agent and hostname info" do
    @agent.increment("test.foo")
    wait
    auth, agent, host = @server.connections.first
    auth.should == 'test_token'
    agent.should =~ /^Instrumental.Agent.Ruby,[\d\.]+$/
    host.should == Socket.gethostname
  end


  it "should report a gauge" do
    now = Time.now
    @agent.gauge('gauge_test', 123)
    wait
    @server.commands.last.should == {
      'gauge' => ["gauge_test 123 #{now.to_i} 1"]
    }
  end

  it "should report a time as gauge and return the block result" do
    now = Time.now
    @agent.time("time_value_test") do
      1 + 1
    end.should == 2
    wait
    @server.commands.last["gauge"].first.should =~ /time_value_test .* #{now.to_i}/
  end

  it "should return the value gauged" do
    now = Time.now
    @agent.gauge('gauge_test', 123).should == 123
    @agent.gauge('gauge_test', 989).should == 989
    wait
  end

  it "should report a gauge with a set time" do
    @agent.gauge('gauge_test', 123, 555)
    wait
    @server.commands.last["gauge"].first.should == "gauge_test 123 555 1"
  end

  it "should report a gauge with a set time and count" do
    @agent.gauge('gauge_test', 123, 555, 111)
    wait
    @server.commands.last["gauge"].first.should == "gauge_test 123 555 111"
  end

  it "should report an increment" do
    now = Time.now
    @agent.increment("increment_test")
    wait
    @server.commands.last["increment"].first.should == "increment_test 1 #{now.to_i} 1"
  end

  it "should return the value incremented by" do
    now = Time.now
    @agent.increment("increment_test").should == 1
    @agent.increment("increment_test", 5).should == 5
    wait
  end

  it "should report an increment a value" do
    now = Time.now
    @agent.increment("increment_test", 2)
    wait
    @server.commands.last["increment"].first.should == "increment_test 2 #{now.to_i} 1"
  end

  it "should report an increment with a set time" do
    @agent.increment('increment_test', 1, 555)
    wait
    @server.commands.last["increment"].first.should == "increment_test 1 555 1"
  end

  it "should report an increment with a set time and count" do
    @agent.increment('increment_test', 1, 555, 111)
    wait
    @server.commands.last["increment"].first.should == "increment_test 1 555 111"
  end

  it "should discard data that overflows the buffer" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      wait
      values = @server.commands.collect do |command|
        command["increment"]
      end.flatten
      values.should     include("overflow_test 1 300 1")
      values.should     include("overflow_test 2 300 1")
      values.should     include("overflow_test 3 300 1")
      values.should_not include("overflow_test 4 300 1")
      values.should_not include("overflow_test 5 300 1")
    end
  end

  it "should send all data in synchronous mode" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      @agent.synchronous = true
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      @agent.instance_variable_get(:@queue).size.should == 0
      wait # let the server receive the commands
      values = @server.commands.collect do |command|
        command["increment"]
      end.flatten
      values.should include("overflow_test 1 300 1")
      values.should include("overflow_test 2 300 1")
      values.should include("overflow_test 3 300 1")
      values.should include("overflow_test 4 300 1")
      values.should include("overflow_test 5 300 1")
    end
  end

  it "should automatically reconnect when forked" do
    wait
    @agent.increment('fork_reconnect_test', 1, 2)
    pid = fork do
      @agent.increment('fork_reconnect_test', 1, 3) # triggers reconnect
    end
    wait
    @agent.increment('fork_reconnect_test', 1, 4) # triggers reconnect
    wait
    @server.connect_count.should >= 2
    values = @server.commands.collect do |command|
      command["increment"]
    end.flatten
    values.should include("fork_reconnect_test 1 2 1")
    values.should include("fork_reconnect_test 1 3 1")
    values.should include("fork_reconnect_test 1 4 1")
  end

  it "should never let an exception reach the user" do
    @agent.stub!(:send_command).and_raise(Exception.new("Test Exception"))
    @agent.increment('throws_exception', 2).should be_nil
    wait
    @agent.gauge('throws_exception', 234).should be_nil
    wait
  end

  it "should let exceptions in time bubble up" do
    expect { @agent.time('za') { raise "fail" } }.to raise_error
  end

  it "should return nil if the user overflows the MAX_BUFFER" do
    1.upto(Instrumental::Agent::MAX_BUFFER) do
      @agent.increment("test").should == 1
      thread = @agent.instance_variable_get(:@thread)
      thread.kill
    end
    @agent.increment("test").should be_nil
  end

  it "should track invalid metrics" do
    @agent.logger.should_receive(:warn).with(/%%/)
    @agent.increment(' %% .!#@$%^&*', 1, 1)
    wait
    @server.commands.last["increment"].first.should =~ /agent.invalid_metric/
  end

  it "should allow reasonable metric names" do
    @agent.increment('a')
    @agent.increment('a.b')
    @agent.increment('hello.world')
    @agent.increment('ThisIsATest.Of.The.Emergency.Broadcast.System.12345')
    wait
    @server.commands.last["increment"].all? { |cmd| cmd !~ /agent.invalid_metric/ }.should be_true
  end

  it "should track invalid values" do
    @agent.logger.should_receive(:warn).with(/hello.*testington/)
    @agent.increment('testington', 'hello')
    wait
    @server.commands.last["increment"].first.should =~ /agent.invalid_value/
  end

  it "should allow reasonable values" do
    @agent.increment('a', -333.333)
    @agent.increment('a', -2.2)
    @agent.increment('a', -1)
    @agent.increment('a',  0)
    @agent.increment('a',  1)
    @agent.increment('a',  2.2)
    @agent.increment('a',  333.333)
    @agent.increment('a',  Float::EPSILON)
    wait
    @server.commands.last["increment"].all? { |cmd| cmd !~ /agent.invalid_value/ }.should be_true
  end

  it "should send notices to the server" do
    tm = Time.now
    @agent.notice("Test note", tm)
    wait
    @server.commands.last["notice"].should include("#{tm.to_i} 0 Test note")
  end

  it "should prevent a note w/ newline characters from being sent to the server" do
    @agent.notice("Test note\n").should be_nil
    wait
    @server.commands.last.should be_nil
  end

  it "should allow outgoing metrics to be stopped" do
    tm = Time.now
    @agent.increment("foo.bar", 1, tm)
    @agent.stop
    wait
    @agent.increment("foo.baz", 1, tm)
    wait
    @server.commands.last["increment"].should include("foo.baz 1 #{tm.to_i} 1")
    @server.commands.last["increment"].should_not include("foo.bar 1 #{tm.to_i} 1")
  end

  it "should allow flushing pending values to the server" do
    1.upto(100) { @agent.gauge('a', rand(50)) }
    @agent.instance_variable_get(:@queue).size.should >= 100
    @agent.flush
    @agent.instance_variable_get(:@queue).size.should ==  0
    wait
    @server.commands.last["gauge"].grep(/^a /).size.should == 100
  end

  it "should no op on an empty flush" do
    @agent.flush(:allow_reconnect => true)
    wait
    @server.commands.should be_empty
  end
end

describe Instrumental::Agent, "connection problems" do
  before do
    Instrumental::Agent.logger = Logger.new("/dev/null")
  end

  after do
    @agent.stop if @agent
    @server.stop if @server
  end

  it "should buffer commands when server is down" do
    @server = TestServer.new(:listen => false)
    @agent = Instrumental::Agent.new('test_token', :reporting_interval => 0.1, :collector => @server.url)
    @agent.increment('reconnect_test', 1, 1234)
    @agent.flush(:async => true)
    wait
    @agent.queue.pop(true).should include(["increment", "reconnect_test 1 1234 1"])
    @agent.failures.should >= 1
  end

  it "should buffer commands when server is not responsive" do
    @server = TestServer.new(:response => false)
    @agent = Instrumental::Agent.new('test_token', :reporting_interval => 0.1, :collector => @server.url, :synchronous => false)
    @agent.increment('reconnect_test', 1, 1234)
    @agent.flush(:async => true)
    wait
    @agent.queue.pop(true).should include(["increment", "reconnect_test 1 1234 1"])
    @agent.failures.should >= 1
  end

  it "should buffer commands when authentication fails" do
    @server = TestServer.new(:authenticate => false)
    @agent = Instrumental::Agent.new('test_token', :reporting_interval => 0.1, :collector => @server.url, :synchronous => false)
    @agent.increment('reconnect_test', 1, 1234)
    @agent.flush(:async => true)
    wait
    @agent.queue.pop(true).should include(["increment", "reconnect_test 1 1234 1"])
    @agent.failures.should >= 1
  end

  it "should warn once when buffer is full" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      @server = TestServer.new(:listen => false)
      @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false)
      @agent.logger.should_receive(:warn).with(/Queue full/).once
      @agent.increment('buffer_full_warn_test', 1, 1234)
      @agent.queue.stub(:pop) { Thread.stop }
      @agent.increment('buffer_full_warn_test', 1, 1234)
      @agent.increment('buffer_full_warn_test', 1, 1234)
      @agent.increment('buffer_full_warn_test', 1, 1234)
      @agent.increment('buffer_full_warn_test', 1, 1234)
      @agent.increment('buffer_full_warn_test', 1, 1234)
    end
  end

  it "should send commands in a short-lived process" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false)
    if pid = fork { @agent.increment('foo', 1, 1234) }
      Process.wait(pid)
      @server.commands.last["increment"].first.should == "foo 1 1234 1"
    end
  end

  it "should send commands in a process that bypasses at_exit when using #cleanup" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false)
    if pid = fork { @agent.increment('foo', 1, 1234); @agent.cleanup; exit! }
      Process.wait(pid)
      @server.commands.last["increment"].first.should == "foo 1 1234 1"
    end
  end

  it "should not wait longer than EXIT_FLUSH_TIMEOUT seconds to exit a process" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false)
    Net::HTTP.any_instance.stub(:request) { |*args| sleep(5) && nil }
    with_constants('Instrumental::Agent::EXIT_FLUSH_TIMEOUT' => 3) do
      if (pid = fork { @agent.increment('foo', 1) })
        tm = Time.now.to_f
        Process.wait(pid)
        diff = Time.now.to_f - tm
        diff.should >= 3
        diff.should < 5
      end
    end
  end

  it "should not wait to exit a process if there are no commands queued" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false)
    Net::HTTP.any_instance.stub(:request) { |*args| sleep(5) && nil }
    with_constants('Instrumental::Agent::EXIT_FLUSH_TIMEOUT' => 3) do
      if (pid = fork { @agent.increment('foo', 1); @agent.queue.clear })
        tm = Time.now.to_f
        Process.wait(pid)
        diff = Time.now.to_f - tm
        diff.should < 1
      end
    end
  end

  it "should not wait longer than EXIT_FLUSH_TIMEOUT to attempt joining the thread and waiting for a final flush" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => false, :reporting_interval => 10)
    @agent.increment('foo', 1)
    @agent.instance_variable_get(:@thread).should_receive(:join).and_return {
      r, w = IO.pipe
      IO.select([r]) # mimic an endless blocking select poll
    }
    with_constants('Instrumental::Agent::EXIT_FLUSH_TIMEOUT' => 3) do
      tm = Time.now.to_f
      @agent.cleanup
      diff = Time.now.to_f - tm
      diff.should <= 4 # accounting for some overhead here, TODO check validity
    end
  end
end

describe Instrumental::Agent, "enabled with sync option" do
  before do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.url, :synchronous => true)
  end

  after do
    @agent.stop
    @server.stop
  end

  it "should send all data in synchronous mode" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      wait # let the server receive the commands
      @server.commands.should include({ "increment" => ["overflow_test 1 300 1"] })
      @server.commands.should include({ "increment" => ["overflow_test 2 300 1"] })
      @server.commands.should include({ "increment" => ["overflow_test 3 300 1"] })
      @server.commands.should include({ "increment" => ["overflow_test 4 300 1"] })
      @server.commands.should include({ "increment" => ["overflow_test 5 300 1"] })
    end
  end

end
