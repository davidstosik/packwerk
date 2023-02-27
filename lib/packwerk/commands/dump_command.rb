# typed: strict
# frozen_string_literal: true

require "csv"

module Packwerk
  module Commands
    class DumpCommand < BaseCommand
      extend T::Sig
      include UsesParseRun

      description "dump Packwerk data"

      sig { override.returns(T::Boolean) }
      def run
        subcommand = args.shift

        case subcommand
        when "references"
          dump_references
        when "files"
          dump_files
        when "packages"
          dump_packages
        else
          err_out.puts("Unknown dump subcommand '#{subcommand}'")
          return false
        end
      end

      private

      sig { returns(T::Boolean) }
      def dump_packages
        file = "./package_dependencies.csv"

        CSV.open(
          file,
          "w",
          write_headers: false
        ) do |csv|
          csv << %w(package dependency)
          run_context.package_set.packages.each do |_name, package|
            package.dependencies.each do |dependency|
              csv << [package.name, dependency]
            end
          end
        end

        out.puts "Exported package dependencies to #{file}"
        true
      end

      sig { returns(T::Boolean) }
      def dump_references
        file = "./references.csv"

        CSV.open(
          file,
          "w",
          write_headers: false
        ) do |csv|
          csv << %w(file constant constant_location constant_package)
          csv.flush

          process_file = T.let(->(relative_file) do
            run_context.references(relative_file: relative_file).each do |reference|
              csv << [
                reference.relative_path,
                reference.constant.name,
                reference.constant.location,
                reference.constant.package.name
              ]
            end
            progress_formatter.increment_progress
            csv.flush
          end, ParseRun::ProcessFileProc)

          progress_formatter.started_inspection(@files_for_processing.files) do
            if configuration.parallel?
              Parallel.each(@files_for_processing.files, &process_file)
            else
              begin
                @files_for_processing.files.each(&process_file)
              rescue Interrupt
                progress_formatter.interrupted
              end
            end
          end
        end

        out.puts "Exported references to #{file}"
        true
      end

      sig { returns(T::Boolean) }
      def dump_files
        file = "./files.csv"

        CSV.open(
          file,
          "w",
          write_headers: false
        ) do |csv|
          csv << %w(path)
          csv.flush

          process_file = T.let(->(relative_file) do
            csv << [relative_file]

            progress_formatter.increment_progress
            csv.flush
          end, ParseRun::ProcessFileProc)

          progress_formatter.started_inspection(@files_for_processing.files) do
            if configuration.parallel?
              Parallel.each(@files_for_processing.files, &process_file)
            else
              begin
                @files_for_processing.files.each(&process_file)
              rescue Interrupt
                progress_formatter.interrupted
              end
            end
          end
        end

        out.puts "Exported files to #{file}"
        true
      end

      sig { returns(RunContext) }
      def run_context
        @run_context ||= RunContext.from_configuration(configuration)
      end
    end
  end
end
