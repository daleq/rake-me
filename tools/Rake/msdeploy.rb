class MSDeploy
	def self.run(attributes)
		tool = attributes.fetch(:tool)
		
		attributes.reject! do |key, value|
			key == :tool
		end
		
		switches = ""
		
		attributes.each do |key, value|
			switches += "-#{key}#{":#{value}" unless value.kind_of? Hash or value.kind_of? TrueClass or value.kind_of? FalseClass}" if value
			
			if value.kind_of? Hash
				switches += ":"
				switches += value.collect { |key, value|
					"#{key}#{"=#{value}" unless value.kind_of? TrueClass or value.kind_of? FalseClass}" if value
				}.join ","
			end
			
			switches += " "
		end
		
		msdeploy = tool.to_absolute
		
		sh "#{msdeploy.escape} #{switches}"
	end
end