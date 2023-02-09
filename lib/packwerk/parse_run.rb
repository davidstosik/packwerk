# typed: strict
# frozen_string_literal: true

require "parallel"

module Packwerk
  class ParseRun
    extend T::Sig

    ProcessFileProc = T.type_alias do
      T.proc.params(path: String).returns(T::Array[Offense])
    end

    sig do
      params(
        relative_file_set: FilesForProcessing::RelativeFileSet,
        configuration: Configuration,
        file_set_specified: T::Boolean,
        offenses_formatter: T.nilable(OffensesFormatter),
        progress_formatter: Formatters::ProgressFormatter,
      ).void
    end
    def initialize(
      relative_file_set:,
      configuration:,
      file_set_specified: false,
      offenses_formatter: nil,
      progress_formatter: Formatters::ProgressFormatter.new(StringIO.new)
    )

      @configuration = configuration
      @progress_formatter = progress_formatter
      @offenses_formatter = T.let(offenses_formatter || configuration.offenses_formatter, Packwerk::OffensesFormatter)
      @relative_file_set = relative_file_set
      @file_set_specified = file_set_specified
    end

    sig { returns(Cli::Result) }
    def update_todo
      if @file_set_specified
        message = <<~MSG.squish
          ⚠️ update-todo must be called without any file arguments.
        MSG

        return Cli::Result.new(message: message, status: false)
      end

      run_context = RunContext.from_configuration(@configuration)
      offense_collection = find_offenses(run_context)
      offense_collection.persist_package_todo_files(run_context.package_set)

      message = <<~EOS
        #{@offenses_formatter.show_offenses(offense_collection.errors)}
        ✅ `package_todo.yml` has been updated.
      EOS

      Cli::Result.new(message: message, status: offense_collection.errors.empty?)
    end

    sig { returns(Cli::Result) }
    def dump_todo
      require "debug"
      run_context = RunContext.from_configuration(@configuration)
      package_set = run_context.package_set
      offense_collection = OffenseCollection.new(@configuration.root_path)

      CSV.open("todos.csv", "w", headers: %w(type constant file), write_headers: true) do |csv|
        package_set.each do |package|
          offense_collection.send(:package_todo_for, package).send(:todo_list).each do |_key, offenses|
            offenses.each do |constant, violations|
              violations["violations"].each do |type|
                violations["files"].each do |file|
                  csv << {
                    "type" => type,
                    "constant" => constant,
                    "file" => file
                  }
                end
              end
            end
          end
        end
      end

      Cli::Result.new(message: "done", status: true)
    end

    sig { returns(Cli::Result) }
    def dump
      run_context = RunContext.new(
        root_path: @configuration.root_path,
        load_paths: @configuration.load_paths,
        package_paths: @configuration.package_paths,
        inflector: ActiveSupport::Inflector,
        custom_associations: @configuration.custom_associations,
        cache_enabled: @configuration.cache_enabled?,
        cache_directory: @configuration.cache_directory,
        config_path: @configuration.config_path,
        checkers: [ReferenceChecking::Checkers::AlwaysTrueChecker.new],
      )

      all_offenses = T.let([], T::Array[Offense])
      process_file = T.let(->(relative_file) do
        run_context.process_file(relative_file: relative_file).tap do |offenses|
          #failed =  offenses.any? { |offense| !offense_collection.listed?(offense) }
          update_progress(failed: false)
        end
      end, ProcessFileProc)

      @progress_formatter.started_inspection(@relative_file_set) do
        all_offenses = if @configuration.parallel?
          Parallel.flat_map(@relative_file_set, &process_file)
        else
          serial_find_offenses(&process_file)
        end
      end

      puts "count: #{all_offenses.count}"
      CSV.open("references.csv", "w", headers: %w(package file constant constant_location constant_package), write_headers: true) do |csv|
        all_offenses.each_slice(1000) do |offenses|
          offenses.each do |offense|
            next unless offense.is_a?(ReferenceOffense)

            csv << {
              "package" => offense.reference.package.name,
              "file" => offense.file,
              "constant" => offense.reference.constant.name,
              "constant_location" => offense.reference.constant.location,
              "constant_package" => offense.reference.constant.package.name,
            }
          end
          csv.flush
        end
      end
      Cli::Result.new(message: "done", status: true)
    end

    sig { returns(Cli::Result) }
    def check
      run_context = RunContext.from_configuration(@configuration)
      offense_collection = find_offenses(run_context, show_errors: true)

      messages = [
        @offenses_formatter.show_offenses(offense_collection.outstanding_offenses),
        @offenses_formatter.show_stale_violations(offense_collection, @relative_file_set),
        @offenses_formatter.show_strict_mode_violations(offense_collection.strict_mode_violations),
      ]

      result_status = offense_collection.outstanding_offenses.empty? &&
        !offense_collection.stale_violations?(@relative_file_set) && offense_collection.strict_mode_violations.empty?

      Cli::Result.new(message: messages.select(&:present?).join("\n") + "\n", status: result_status)
    end

    private

    sig { params(run_context: RunContext, show_errors: T::Boolean).returns(OffenseCollection) }
    def find_offenses(run_context, show_errors: false)
      offense_collection = OffenseCollection.new(@configuration.root_path)
      all_offenses = T.let([], T::Array[Offense])
      process_file = T.let(->(relative_file) do
        run_context.process_file(relative_file: relative_file).tap do |offenses|
          failed = show_errors && offenses.any? { |offense| !offense_collection.listed?(offense) }
          update_progress(failed: failed)
        end
      end, ProcessFileProc)

      @progress_formatter.started_inspection(@relative_file_set) do
        all_offenses = if @configuration.parallel?
          Parallel.flat_map(@relative_file_set, &process_file)
        else
          serial_find_offenses(&process_file)
        end
      end

      all_offenses.each { |offense| offense_collection.add_offense(offense) }
      offense_collection
    end

    sig { params(block: ProcessFileProc).returns(T::Array[Offense]) }
    def serial_find_offenses(&block)
      all_offenses = T.let([], T::Array[Offense])
      begin
        @relative_file_set.each do |relative_file|
          offenses = yield(relative_file)
          all_offenses.concat(offenses)
        end
      rescue Interrupt
        @progress_formatter.interrupted
        all_offenses
      end
      all_offenses
    end

    sig { params(failed: T::Boolean).void }
    def update_progress(failed: false)
      if failed
        @progress_formatter.mark_as_failed
      else
        @progress_formatter.mark_as_inspected
      end
    end
  end

  private_constant :ParseRun
end
