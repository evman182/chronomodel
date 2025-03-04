require 'active_record/connection_adapters/postgresql_adapter'

require 'chrono_model/adapter/migrations'

if ActiveRecord::VERSION::STRING >= '6.1'
  require 'chrono_model/adapter/migrations_modules/stable'
else
  require 'chrono_model/adapter/migrations_modules/legacy'
end

require 'chrono_model/adapter/ddl'
require 'chrono_model/adapter/indexes'
require 'chrono_model/adapter/tsrange'
require 'chrono_model/adapter/upgrade'

module ChronoModel

  # This class implements all ActiveRecord::ConnectionAdapters::SchemaStatements
  # methods adding support for temporal extensions. It inherits from the Postgres
  # adapter for a clean override of its methods using super.
  #
  class Adapter < ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    include ChronoModel::Adapter::Migrations
    include ChronoModel::Adapter::DDL
    include ChronoModel::Adapter::Indexes
    include ChronoModel::Adapter::TSRange
    include ChronoModel::Adapter::Upgrade

    # The schema holding current data
    TEMPORAL_SCHEMA = 'temporal'

    # The schema holding historical data
    HISTORY_SCHEMA  = 'history'

    # Returns true whether the connection adapter supports our
    # implementation of temporal tables. Currently, Chronomodel
    # is supported starting with PostgreSQL 9.3.
    #
    def chrono_supported?
      postgresql_version >= 90300
    end

    def chrono_setup!
      chrono_ensure_schemas

      chrono_upgrade_warning
    end

    # Runs primary_key, indexes and default_sequence_name in the
    # temporal schema, as the table there defined is the source for
    # this information.
    #
    # Moreover, the PostgreSQLAdapter +indexes+ method uses
    # current_schema(), thus this is the only (and cleanest) way to
    # make injection work.
    #
    # Schema nesting is disabled on these calls, make sure to fetch
    # metadata from the first caller's selected schema and not from
    # the current one.
    #
    # NOTE: These methods are dynamically defined, see the source.
    #
    def primary_key(table_name)
    end

    [:primary_key, :indexes, :default_sequence_name].each do |method|
      define_method(method) do |*args|
        table_name = args.first
        return super(*args) unless is_chrono?(table_name)
        on_schema(TEMPORAL_SCHEMA, recurse: :ignore) { super(*args) }
      end
    end

    # Runs column_definitions in the temporal schema, as the table there
    # defined is the source for this information.
    #
    # The default search path is included however, since the table
    # may reference types defined in other schemas, which result in their
    # names becoming schema qualified, which will cause type resolutions to fail.
    #
    # NOTE: This method is dynamically defined, see the source.
    #
    def column_definitions
    end

    define_method(:column_definitions) do |table_name|
      return super(table_name) unless is_chrono?(table_name)
      on_schema(TEMPORAL_SCHEMA + ',' + self.schema_search_path, recurse: :ignore) { super(table_name) }
    end

    # Evaluates the given block in the temporal schema.
    #
    def on_temporal_schema(&block)
      on_schema(TEMPORAL_SCHEMA, &block)
    end

    # Evaluates the given block in the history schema.
    #
    def on_history_schema(&block)
      on_schema(HISTORY_SCHEMA, &block)
    end

    # Evaluates the given block in the given +schema+ search path.
    #
    # Recursion works by saving the old_path the function closure
    # at each recursive call.
    #
    # See specs for examples and behaviour.
    #
    def on_schema(schema, recurse: :follow)
      old_path = self.schema_search_path

      count_recursions do
        if recurse == :follow or Thread.current['recursions'] == 1
          self.schema_search_path = schema
        end

        yield
      end

    ensure
      # If the transaction is aborted, any execute() call will raise
      # "transaction is aborted errors" - thus calling the Adapter's
      # setter won't update the memoized variable.
      #
      # Here we reset it to +nil+ to refresh it on the next call, as
      # there is no way to know which path will be restored when the
      # transaction ends.
      #
      transaction_aborted =
        chrono_connection.transaction_status == PG::Connection::PQTRANS_INERROR

      if transaction_aborted && Thread.current['recursions'] == 1
        @schema_search_path = nil
      else
        self.schema_search_path = old_path
      end
    end

    # Returns true if the given name references a temporal table.
    #
    def is_chrono?(table)
      on_temporal_schema { data_source_exists?(table) } &&
        on_history_schema { data_source_exists?(table) }
    end

    # Reads the Gem metadata from the COMMENT set on the given PostgreSQL
    # view name.
    #
    def chrono_metadata_for(view_name)
      comment = select_value(
        "SELECT obj_description(#{quote(view_name)}::regclass)",
        "ChronoModel metadata for #{view_name}") if data_source_exists?(view_name)

      MultiJson.load(comment || '{}').with_indifferent_access
    end

    # Writes Gem metadata on the COMMENT field in the given VIEW name.
    #
    def chrono_metadata_set(view_name, metadata)
      comment = MultiJson.dump(metadata)

      execute %[ COMMENT ON VIEW #{view_name} IS #{quote(comment)} ]
    end

    def valid_table_definition_options
      super + [:temporal, :journal, :no_journal, :full_journal]
    end

    private
      # Rails 7.1 uses `@raw_connection`, older versions use `@connection`
      #
      def chrono_connection
        @chrono_connection ||= @raw_connection || @connection
      end

      # Counts the number of recursions in a thread local variable
      #
      def count_recursions # yield
        Thread.current['recursions'] ||= 0
        Thread.current['recursions'] += 1

        yield

      ensure
        Thread.current['recursions'] -= 1
      end

      # Create the temporal and history schemas, unless they already exist
      #
      def chrono_ensure_schemas
        [TEMPORAL_SCHEMA, HISTORY_SCHEMA].each do |schema|
          execute "CREATE SCHEMA #{schema}" unless schema_exists?(schema)
        end
      end
  end

end
