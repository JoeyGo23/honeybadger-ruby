require 'securerandom'

require 'honeybadger/agent'

module Honeybadger
  class Trace
    attr_reader :id, :duration, :key

    def self.current
      Thread.current[:__hb_trace]
    end

    def self.create(id)
      Thread.current[:__hb_trace] = new(id)
    end

    def self.instrument(key, payload = {}, &block)
      new(SecureRandom.uuid).instrument(key, payload, &block)
    end

    def initialize(id)
      @id = id
      @events = []
      @meta = {}
      @fast_queries = {}
      @duration = 0
    end

    def add(event)
      ce = clean_event(event)
      @events << ce.to_a if ce.render?
    end

    def add_query(event)
      if event.duration < 6
        ce = clean_event(event)
        return unless ce.render?
        query = ce.to_s
        if @fast_queries[query]
          @fast_queries[query][:duration] += ce.event.duration
          @fast_queries[query][:count] += 1
        else
          @fast_queries[query] = { :duration => ce.event.duration, :count => 1 }
        end
      else
        add(event)
      end
    end

    def complete(event)
      @meta = clean_event(event).to_h
      @duration = event.duration
      @key = "#{event.payload[:controller]}##{event.payload[:action]}"
      Thread.current[:__hb_trace] = nil
      Agent.trace(self)
    end

    def instrument(key, payload)
      @key = key
      @meta = payload
      started = Time.now
      yield
    rescue Exception => e
      @meta[:exception] = [e.class.name, e.message]
      raise e
    ensure
      @meta.merge!(:duration => @duration = 1000.0 * (Time.now - started))
      Agent.trace(self)
    end

    def to_h
      @meta.merge({ :events => @events, :key => @key, :fast_queries => @fast_queries.map {|k,v| [ k, v[:duration], v[:count] ] } })
    end

    protected

    def clean_event(event)
      TraceCleaner.create(event)
    end

  end

  module TraceCleaner

    def self.create(event)
      Classes[event.name].new(event)
    end

    class Base
      attr_reader :event

      def initialize(event)
        @event = event
      end

      def render?
        true
      end

      def payload
        event.payload
      end

      def to_s
        payload[:path] || payload[:key] || payload.inspect
      end

      def to_h
        { :name => event.name, :desc => to_s, :duration => event.duration }
      end

      def to_a
        [ event.name, event.duration, to_s ]
      end

    end

    class NetHttpRequest < Base
      Replacement = "..."
      def to_s
        uri = payload[:uri]
        uri.user = Replacement if uri.user
        uri.password = Replacement if uri.password
        uri.query = Replacement if uri.query
        "#{payload[:method]} #{uri}"
      end
    end

    class ActiveRecord < Base
      Schema = "SCHEMA".freeze
      SchemaMigrations = /schema_migrations/.freeze
      EscapedQuotes = /(\\"|\\')/.freeze
      SQuotedData = /'(?:[^']|'')*'/.freeze
      DQuotedData = /"(?:[^"]|"")*"/.freeze
      NumericData = /\b\d+\b/.freeze
      Newline = /\n/.freeze
      Replacement = "?".freeze
      EmptyReplacement = "".freeze
      DoubleQuoters = /(postgres|sqlite|postgis)/.freeze

      def render?
        event.payload[:name] != Schema && !event.payload[:sql].match(SchemaMigrations)
      end

      def to_s
        return "Super long query" if event.payload[:sql].length > 1024
        sql = event.payload[:sql]
        sql = sql.gsub(EscapedQuotes, EmptyReplacement).gsub(SQuotedData, Replacement)
        sql = sql.gsub(DQuotedData, Replacement) unless ::ActiveRecord::Base.connection_pool.spec.config[:adapter] =~ DoubleQuoters
        sql.gsub(NumericData, Replacement).gsub(Newline, EmptyReplacement).squeeze(' ')
      end
    end

    class ActionView < Base
      EmptyReplacement = "".freeze

      def to_s
        event.payload[:identifier].to_s.gsub(::Rails.root.to_s + '/', EmptyReplacement)
      end
    end

    class ActionController < Base
      def payload
        event.payload.reject {|k, v| k == :params }
      end

      def to_s
        payload.inspect
      end

      def to_h
        payload.merge({ :duration => event.duration })
      end
    end

    Classes = Hash.new(Base).merge({
      'sql.active_record' => ActiveRecord,
      'render_template.action_view' => ActionView,
      'render_partial.action_view' => ActionView,
      'render_collection.action_view' => ActionView,
      'process_action.action_controller' => ActionController,
      'net_http.request' => NetHttpRequest
    })
  end
end
