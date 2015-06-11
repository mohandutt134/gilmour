# encoding: utf-8
require 'rspec/given'
require 'securerandom'
require './testservice/test_service_base'

require_relative 'helpers/connection'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = [:should, :expect]
  end
end

def install_test_subscriber(parent)
  waiter = Thread.new { loop { sleep 1 } }
  TestSubscriber.callback do |topic, data|
    @topic = topic
    @data = data
    waiter.kill
  end
  waiter
end

describe 'TestSubscriber' do
  test_subscriber_path = './testservice/subscribers/test_subscriber'
  after(:all) do
    EM.stop
  end
  Given(:subscriber) { TestServiceBase }
  Given { subscriber.load_subscriber(test_subscriber_path) }
  Then do
    handlers = subscriber.subscribers(TestSubscriber::Topic)
    module_present = handlers.find { |h| h[:subscriber] == TestSubscriber }
    module_present.should be_truthy
  end

  context 'Running Service' do
    before(:all) do
      @service = TestServiceBase.new(redis_connection_options, 'redis')
    end
    Given(:connection_opts) { redis_connection_options }
    before(:all) do
      @service.registered_subscribers.each do |s|
        s.backend = 'redis'
      end
      @service.start
    end

    context 'Handler Register' do
      When { install_test_subscriber(subscriber) }
      context 'Check registered handlers' do
        When(:handlers) do
          subscriber.subscribers(TestSubscriber::Simulation)
          .map { |h| h[:handler] }
        end
        Then { handlers.each { |h| h.should be_kind_of Proc } }
        Then  do
          arg1 = TestSubscriber::Simulation
          handlers.each do |h|
            arg2 = SecureRandom.hex
            # simualate a handler call
            h.call(arg1, arg2)
            @topic.should be == arg1
            @data.should be == arg2
          end
        end
      end
    end

    context 'Receive messages' do
      context 'Receive a message' do
        Given(:ping_opts) { redis_ping_options }
        When do
          @data = @topic = nil
          waiter = install_test_subscriber(TestServiceBase)
          redis_publish_async(connection_opts,
                              ping_opts[:message],
                              TestSubscriber::Topic)
          waiter.join
        end
        Then do
          @data.should be == ping_opts[:message]
          @topic.should be == TestSubscriber::Topic
        end
        And { expect(EM.reactor_thread.alive?).to be_truthy }
      end

      context 'Recieve a message on a wildcard key' do
        Given(:wildcard_opts) { redis_wildcard_options }
        When do
          @data = @topic = nil
          waiter = install_test_subscriber(TestServiceBase)
          redis_publish_async(connection_opts,
                              wildcard_opts[:message],
                              wildcard_opts[:topic])
          waiter.join
        end
        Then { @data.should == wildcard_opts[:message] }
        And  { @topic.should == wildcard_opts[:topic] }
      end
    end

    context 'Publish sans subscriber timeout' do
      Given(:ping_opts) do
        redis_ping_options
      end

      When(:sub) do
        Gilmour::RedisBackend.new({})
      end
      When(:response) do
        waiter = Thread.new { loop { sleep 1 } }
        data = code = nil
        sub.publish(ping_opts[:message], "hello.world") do |d, c|
          data = d
          code = c
          waiter.kill
        end
        waiter.join(5)
        [data, code]
      end
      Then do
        data, code = response
        data.should be == nil
        code.should be == nil
      end

    end

    context 'Send and receive a message' do
      Given(:ping_opts) { redis_ping_options }
      When(:sub) do
        Gilmour::RedisBackend.new({})
      end
      When(:response) do
        waiter = Thread.new { loop { sleep 1 } }
        data = code = nil
        sub.publish(ping_opts[:message], TestSubscriber::Topic, { confirm_subscriber: true }) do |d, c|
          data = d
          code = c
          waiter.kill
        end
        waiter.join
        [data, code]
      end
      Then do
        data, code = response
        data.should be == ping_opts[:response]
        code.should be == 200
      end
    end

    context 'Send once, Receive twice' do
      Given(:ping_opts) { redis_ping_options }
      When(:sub) do
        Gilmour::RedisBackend.new({})
      end
      When (:response) do
        waiter = Thread.new { loop { sleep 1 } }

        actual_ret = []

        sub.add_listener TestSubscriber::GroupReturn do
          actual_ret.push(request.body)
          waiter.kill if actual_ret.length == 2
        end

        sub.publish(ping_opts[:message], TestSubscriber::GroupTopic)

        waiter.join
        actual_ret
      end
      Then do
        expected = [ping_opts[:message], 2]
        response.should be == expected + expected
      end
    end

    context 'Send once, Receive Once' do
      Given(:ping_opts) { redis_ping_options }
      When(:sub) do
        Gilmour::RedisBackend.new({})
      end
      When (:response) do
        waiter = Thread.new { loop { sleep 1 } }

        actual_ret = []

        sub.add_listener TestSubscriber::GroupReturn do
          actual_ret.push(request.body)
          waiter.kill if actual_ret.length == 1
        end

        sub.publish(ping_opts[:message], TestSubscriber::ExclusiveTopic)

        waiter.join
        actual_ret
      end
      Then do
        response.should be == [0]
      end
    end

    context 'Send message from subscriber' do
      Given(:ping_opts) { redis_ping_options }
      When(:sub) do
        Gilmour::RedisBackend.new({})
      end
      When (:response) do
        data = code = nil
        waiter = Thread.new { loop { sleep 1 } }
        sub.publish(ping_opts[:message], 'test.republish') do |d, c|
          data = d
          code = c
          waiter.kill
        end
        waiter.join
        [data, code]
      end
      Then do
        data, code = response
        data.should be == ping_opts[:response]
        code.should be == 200
      end
      And { expect(EM.reactor_thread.alive?).to be_truthy }
    end


  end
end
