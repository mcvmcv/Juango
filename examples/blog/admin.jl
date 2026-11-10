Admin.register!(Post; list_display = [:title, :author, :published, :created, "Comments" => p -> count(p.comments)],
                search_fields = [:title, :body], list_filter = [:published, :author])
Admin.register!(Comment; list_display = [:__str__, :post, :approved, :created],
                search_fields = [:name, :body], list_filter = [:approved])
