require 'em-hiredis'
require_relative 'backend'

module Gilmour
  class RedisBackend < Backend
    implements 'redis'

    attr_reader :subscriber
    attr_reader :publisher

    def initialize(opts)
      @response_handlers = {}
      @subscriptions = {}
      waiter = Thread.new { loop { sleep 1 } }
      Thread.new do
        EM.run do
          @publisher = EM::Hiredis.connect
          @subscriber = @publisher.pubsub
          waiter.kill
        end
      end
      waiter.join
    end

    def execute_handler(topic, payload, handler)
      data, sender = Gilmour::Protocol.parse_request(payload)
      body, code = Gilmour::Responder.new(topic, data)
      .execute(handler)
      send_async(body, "response.#{sender}", code) if code && sender
    end

    def subscribe_topic(topic)
      method = topic.index('*') ? :psubscribe : :subscribe
      @subscriber.method(method).call(topic)
    end

    def pmessage_handler(key, matched_topic, payload)
      @subscriptions[key].each do |subscription|
        execute_handler(matched_topic, payload, subscription[:handler])
      end
    end

    def register_response(sender, handler)
      topic = "response.#{sender}"
      @response_handlers[topic] = handler
      subscribe_topic(topic)
    end

    def response_handler(sender, payload)
      data, code, _ = Gilmour::Protocol.parse_response(payload)
      handler = @response_handlers[sender]
      if handler
        handler.call(data, code)
        @subscriber.unsubscribe(sender)
        @response_handlers.delete(sender)
      end
    end

    def setup_subscribers(subs = {})
      @subscriptions = subs
      EM.defer do
        subs.keys.each { |topic| subscribe_topic(topic) }
        @subscriber.on(:pmessage) do |key, topic, payload|
          pmessage_handler(key, topic, payload)
        end
        @subscriber.on(:message) do |topic, payload|
          if topic.start_with? 'response.'
            response_handler(topic, payload)
          else
            pmessage_handler(topic, topic, payload)
          end
        end
      end
    end

    def send_async(data, destination, code = nil)
      payload, sender = Gilmour::Protocol.create_request(data, code)
      @publisher.publish(destination, payload)
      sender
    end
    alias_method :publish, :send_async

    def send(message, destination)
      payload, sender = Gilmour::Protocol.create_request(message)
      register_response(sender, Proc.new)
      @publisher.publish(destination, payload)
    end
  end
end
