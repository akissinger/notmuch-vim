if exists("g:loaded_notmuch")
	finish
endif

if !has("ruby") || version < 700
	finish
endif

let g:loaded_notmuch = "yep"

let g:notmuch_folders_maps = {
	\ '<Enter>':	'folders_show_search()',
	\ 's':		'folders_search_prompt()',
	\ '=':		'folders_refresh()',
	\ 'c':		'compose()',
	\ }

let g:notmuch_search_maps = {
	\ 'q':		'kill_this_buffer()',
	\ '<Enter>':	'search_show_thread(1)',
	\ '<Space>':	'search_show_thread(2)',
	\ 'A':		'search_tag("-inbox -unread")',
	\ 'I':		'search_tag("-unread")',
	\ 't':		'search_tag("")',
	\ 's':		'search_search_prompt()',
	\ '=':		'search_refresh()',
	\ '?':		'search_info()',
	\ 'c':		'compose()',
	\ }

let g:notmuch_show_maps = {
	\ 'q':		'kill_this_buffer()',
	\ 'A':		'show_tag("-inbox -unread")',
	\ 'I':		'show_tag("-unread")',
	\ 't':		'show_tag("")',
	\ 'o':		'show_open_msg()',
	\ 'e':		'show_extract_msg()',
	\ 'v':		'show_view_attachment()',
	\ 's':		'show_save_msg()',
	\ 'p':		'show_save_patches()',
	\ 'r':		'show_reply()',
	\ '?':		'show_info()',
	\ '<Tab>':	'show_next_msg(1)',
	\ '<S-Tab>':  'show_next_msg(-1)',
	\ 'c':		'compose()',
	\ '<Enter>': 'fold_message()',
	\ }

let g:notmuch_compose_maps = {
	\ ',s':		'compose_send()',
	\ ',q':		'compose_quit()',
	\ }

let s:notmuch_folders_default = [
	\ [ 'new', 'tag:inbox and tag:unread' ],
	\ [ 'inbox', 'tag:inbox' ],
	\ [ 'unread', 'tag:unread' ],
	\ ]

let s:notmuch_view_attachment_default = 'xdg-open'
let s:notmuch_attachment_tmpdir_default = '~/.notmuch/tmp'
let s:notmuch_compose_start_insert_default = 1
let s:notmuch_date_format_default = '%d.%m.%y'
let s:notmuch_datetime_format_default = '%d.%m.%y %H:%M:%S'
let s:notmuch_reader_default = 'mutt -f %s'
let s:notmuch_sendmail_default = 'sendmail'
let s:notmuch_save_sent_locally_default = 1
let s:notmuch_save_sent_mailbox_default = 'Sent'
let s:notmuch_folders_count_threads_default = 0

function! s:new_file_buffer(type, fname)
	exec printf('edit %s', a:fname)
	execute printf('set filetype=notmuch-%s', a:type)
	execute printf('set syntax=notmuch-%s', a:type)
	ruby $curbuf.init(VIM::evaluate('a:type'))
endfunction

function! s:on_compose_delete()
	if b:compose_done
		return
	endif
	if input('[s]end/[q]uit? ') =~ '^s'
		call s:compose_send()
	endif
endfunction

"" actions

function! s:compose_quit()
	let b:compose_done = 1
	call s:kill_this_buffer()
endfunction

function! s:compose_send()
	let b:compose_done = 1
	let fname = expand('%')
	let lines = getline(5, '$')

ruby << EOF
	# Generate proper mail to send
	text = VIM::evaluate('lines').join("\n")
	fname = VIM::evaluate('fname')
	transport = Mail.new(text)
	transport.message_id = generate_message_id
	transport.charset = 'utf-8'
	File.write(fname, transport.to_s)
EOF

	let cmdtxt = g:notmuch_sendmail . ' -t -f ' . s:reply_from . ' < ' . fname
	let out = system(cmdtxt)
	let err = v:shell_error
	if err
		echohl Error
		echo 'Eeek! unable to send mail'
		echo out
		echohl None
		return
	endif

	if g:notmuch_save_sent_locally
		let out = system('notmuch insert --create-folder --folder=' . g:notmuch_save_sent_mailbox . ' +sent -unread -inbox < ' . fname)
		let err = v:shell_error
		if err
			echohl Error
			echo 'Eeek! unable to save sent mail'
			echo out
			echohl None
			return
		endif
	endif
	call delete(fname)
	echo 'Mail sent successfully.'
	call s:kill_this_buffer()
endfunction

function! s:show_next_msg(shift)
ruby << EOF
	shift = VIM::evaluate('a:shift')
	r, c = $curwin.cursor
	n = $curbuf.line_number
	i = $messages.index { |m| n >= m.start && n <= m.end } + shift
	if i >= 0 and i < $messages.length
		m = $messages[i]
		if m
			r = m.body_start + 1
			VIM::command("normal #{m.start}zt")
			$curwin.cursor = r, c
		end
	end
EOF
endfunction

function! s:show_reply()
	ruby open_reply get_message.mail
	let b:compose_done = 0
	call s:set_map(g:notmuch_compose_maps)
	autocmd BufDelete <buffer> call s:on_compose_delete()
	if g:notmuch_compose_start_insert
		startinsert!
	end
endfunction

function! s:compose()
	ruby open_compose
	let b:compose_done = 0
	call s:set_map(g:notmuch_compose_maps)
	autocmd BufDelete <buffer> call s:on_compose_delete()
	if g:notmuch_compose_start_insert
		startinsert!
	end
endfunction

function! s:show_info()
	ruby vim_puts get_message.inspect
endfunction

function! s:show_view_attachment()
	let line = getline(".")
ruby << EOF
	m = get_message
	line = VIM::evaluate('line')

	match = line.match(/^Attachment (\d*):/)
	if match and match.length == 2
		a = m.mail.attachments[match[1].to_i - 1]
		tmpdir = VIM::evaluate('g:notmuch_attachment_tmpdir')
		tmpdir = File.expand_path(tmpdir)
		Dir.mkdir(tmpdir) unless Dir.exists?(tmpdir)
		filename = File.expand_path("#{tmpdir}/#{a.filename}")
		vim_puts "Viewing attachment #{filename}"
		File.open(filename, 'w') do |f|
			f.write a.body.decoded
		end
		cmd = VIM::evaluate('g:notmuch_view_attachment')
		spawn(cmd, filename)
	else
		vim_puts "No attachment on this line."
	end
EOF
endfunction

function! s:show_extract_msg()
	let line = getline(".")
ruby << EOF
	m = get_message
	line = VIM::evaluate('line')

	# If the user is on a line that has an 'Attachment'
	# line, we just extract the one attachment.
	match = line.match(/^Attachment (\d*):/)
	if match and match.length == 2
		a = m.mail.attachments[match[1].to_i - 1]
		File.open(a.filename, 'w') do |f|
			f.write a.body.decoded
			vim_puts "Extracted #{a.filename}"
		end
	else
		# Extract them all..
		m.mail.attachments.each do |a|
			File.open(a.filename, 'w') do |f|
				f.write a.body.decoded
				vim_puts "Extracted #{a.filename}"
			end
		end
	end
EOF
endfunction

function! s:show_open_msg()
ruby << EOF
	m = get_message
	mbox = File.expand_path('~/.notmuch/vim_mbox')
	cmd = VIM::evaluate('g:notmuch_reader') % mbox
	system "notmuch show --format=mbox id:#{m.message_id} > #{mbox} && #{cmd}"
EOF
endfunction

function! s:show_save_msg()
	let file = input('File name: ')
ruby << EOF
	file = VIM::evaluate('file')
	m = get_message
	system "notmuch show --format=mbox id:#{m.message_id} > #{file}"
EOF
endfunction

function! s:show_save_patches()
ruby << EOF
	q = $curbuf.query($cur_thread)
	t = q.search_threads.first
	n = 0
	t.toplevel_messages.first.replies.each do |m|
		next if not m['subject'] =~ /^\[PATCH.*\]/
		file = "%04d.patch" % [n += 1]
		system "notmuch show --format=mbox id:#{m.message_id} > #{file}"
	end
	vim_puts "Saved #{n} patches"
EOF
endfunction

function! s:show_tag(intags)
	if empty(a:intags)
		let tags = input('tags: ')
	else
		let tags = a:intags
	endif
	ruby do_tag(get_cur_view, VIM::evaluate('l:tags'))
	call s:show_next_thread()
endfunction

function! s:search_search_prompt()
	let text = input('Search: ')
	if text == ""
		return
	endif
	setlocal modifiable
ruby << EOF
	$cur_search = VIM::evaluate('text')
	$curbuf.reopen
	search_render($cur_search)
EOF
	setlocal nomodifiable
endfunction

function! s:search_info()
	ruby vim_puts get_thread_id
endfunction

function! s:search_refresh()
	setlocal modifiable
	ruby $curbuf.reopen
	ruby search_render($cur_search)
	setlocal nomodifiable
endfunction

function! NotmuchTags(A, L, P)
	return system("notmuch search --output=tags '*'")
endfunction

function! s:search_tag(intags)
	if empty(a:intags)
		let tags = input('tags: ', '', 'custom,NotmuchTags')
	else
		let tags = a:intags
	endif
	ruby do_tag(get_thread_id, VIM::evaluate('l:tags'))
	norm j
endfunction

function! s:folders_search_prompt()
	let text = input('Search: ')
	call s:search(text)
endfunction

function! s:folders_refresh()
	setlocal modifiable
	ruby $curbuf.reopen
	ruby folders_render()
	setlocal nomodifiable
endfunction

"" basic

function! s:show_cursor_moved()
ruby << EOF
	if $curbuf.renderer.is_ready?
		VIM::command('setlocal modifiable')
		$curbuf.renderer.do_next
		VIM::command('setlocal nomodifiable')
	end
EOF
endfunction

function! s:show_next_thread()
	call s:kill_this_buffer()
	if line('.') != line('$')
		norm j
		call s:search_show_thread(0)
	else
		echo 'No more messages.'
	endif
endfunction

function! s:kill_this_buffer()
ruby << EOF
	$curbuf.close
	VIM::command("bdelete!")
EOF
endfunction

function! s:set_map(maps)
	nmapclear <buffer>
	for [key, code] in items(a:maps)
		let cmd = printf(":call <SID>%s<CR>", code)
		exec printf('nnoremap <buffer> %s %s', key, cmd)
	endfor
endfunction

function! s:fresh_buffer_name(base)
	let fresh = 0
	let name = ""
	while name == ""
		if fresh == 0
			let name = a:base
		else
			let name = a:base . "-" . fresh
		endif

		for i in range(1, bufnr('$'))
			if buflisted(i) && stridx(bufname(i), name) != -1
				let name = ""
				let fresh = fresh + 1
				break
			endif
		endfor
	endwhile
	exec printf('file %s', name)
	" file a:base
endfunction

function! s:new_buffer(type)
	enew
	setlocal buftype=nofile bufhidden=hide
	setlocal foldtext=getline(v:foldstart)
	keepjumps 0d
	execute printf('set filetype=notmuch-%s', a:type)
	execute printf('set syntax=notmuch-%s', a:type)
	call s:fresh_buffer_name(a:type)
ruby << EOF
	ty = VIM::evaluate('a:type')
	$curbuf.init(ty)
EOF
endfunction

function! s:set_menu_buffer()
	setlocal nomodifiable
	setlocal cursorline
	setlocal nowrap
endfunction

function! s:fold_message()
	normal za
endfunction

"" main

function! s:show(thread_id)
	call s:new_buffer('show')
	setlocal modifiable
ruby << EOF
	thread_id = VIM::evaluate('a:thread_id')
	$cur_thread = thread_id
	$messages.clear
	$curbuf.render do |b|
		q = $curbuf.query(get_cur_view)
		q.sort = Notmuch::SORT_OLDEST_FIRST
		msgs = q.search_messages
		msgs.each do |msg|
			m = Mail.read(msg.filename)
			part = m.find_first_text
			nm_m = Message.new(msg, m)
			$messages << nm_m
			date_fmt = VIM::evaluate('g:notmuch_datetime_format')
			date = Time.at(msg.date).strftime(date_fmt)
			nm_m.start = b.count
			b << "%s %s (%s)" % [msg['from'], date, msg.tags]
			b << "Subject: %s" % [msg['subject']]
			b << "To: %s" % msg['to']
			b << "Cc: %s" % msg['cc']
			b << "Date: %s" % msg['date']
			cnt = 0
			nm_m.mail.attachments.each do |a|
				cnt += 1
				b << "Attachment %d: %s" % [cnt, a.filename]
			end
			nm_m.body_start = b.count
			b << "--- %s ---" % part.mime_type
			part.convert.each_line do |l|
				b << l.chomp
			end
			b << " "
			b << " "
			nm_m.end = b.count

			# create folds for all messages, and open them
			# when a message is unread
			VIM::command("#{nm_m.start+1},#{nm_m.end}fold")
			if msg.tags.include?('unread')
				VIM::command("#{nm_m.start+1}foldopen")
			end
		end
		b.delete(b.count)
	end
	$messages.each_with_index do |msg, i|
		VIM::command("syntax region nmShowMsg#{i}Desc start='\\%%%il' end='\\%%%il' contains=@nmShowMsgDesc" % [msg.start, msg.start + 1])
		VIM::command("syntax region nmShowMsg#{i}Head start='\\%%%il' end='\\%%%il' contains=@nmShowMsgHead" % [msg.start + 1, msg.body_start])
		VIM::command("syntax region nmShowMsg#{i}Body start='\\%%%il' end='\\%%%dl' contains=@nmShowMsgBody" % [msg.body_start, msg.end])
	end
EOF
	setlocal nomodifiable
	call s:set_map(g:notmuch_show_maps)
endfunction

function! s:search_show_thread(mode)
ruby << EOF
	mode = VIM::evaluate('a:mode')
	id = get_thread_id
	case mode
	when 0;
	when 1; $cur_filter = nil
	when 2; $cur_filter = $cur_search
	end
	VIM::command("call s:show('#{id}')")
EOF
endfunction

function! s:search(search)
	call s:new_buffer('search')
ruby << EOF
	$cur_search = VIM::evaluate('a:search')
	search_render($cur_search)
EOF
	call s:set_menu_buffer()
	call s:set_map(g:notmuch_search_maps)
	autocmd CursorMoved <buffer> call s:show_cursor_moved()
endfunction

function! s:folders_show_search()
ruby << EOF
	n = $curbuf.line_number
	# s = $searches[n - 1]
	folders = VIM::evaluate('g:notmuch_folders')
	VIM::command("call s:search('#{folders[n-1][1]}')")
	VIM::command("call s:fresh_buffer_name('#{folders[n-1][0]}')")
EOF
endfunction

function! s:folders()
	call s:new_buffer('folders')
	ruby folders_render()
	call s:set_menu_buffer()
	call s:set_map(g:notmuch_folders_maps)
endfunction

"" root

function! s:set_defaults()
	if !exists('g:notmuch_save_sent_locally')
		let g:notmuch_save_sent_locally = s:notmuch_save_sent_locally_default
	endif

	if !exists('g:notmuch_save_sent_mailbox')
		let g:notmuch_save_sent_mailbox = s:notmuch_save_sent_mailbox_default
	endif

	if !exists('g:notmuch_date_format')
		if exists('g:notmuch_rb_date_format')
			let g:notmuch_date_format = g:notmuch_rb_date_format
		else
			let g:notmuch_date_format = s:notmuch_date_format_default
		endif
	endif

	if !exists('g:notmuch_datetime_format')
		if exists('g:notmuch_rb_datetime_format')
			let g:notmuch_datetime_format = g:notmuch_rb_datetime_format
		else
			let g:notmuch_datetime_format = s:notmuch_datetime_format_default
		endif
	endif

	if !exists('g:notmuch_reader')
		if exists('g:notmuch_rb_reader')
			let g:notmuch_reader = g:notmuch_rb_reader
		else
			let g:notmuch_reader = s:notmuch_reader_default
		endif
	endif

	if !exists('g:notmuch_sendmail')
		if exists('g:notmuch_rb_sendmail')
			let g:notmuch_sendmail = g:notmuch_rb_sendmail
		else
			let g:notmuch_sendmail = s:notmuch_sendmail_default
		endif
	endif

	if !exists('g:notmuch_attachment_tmpdir')
		let g:notmuch_attachment_tmpdir = s:notmuch_attachment_tmpdir_default
	endif

	if !exists('g:notmuch_view_attachment')
		let g:notmuch_view_attachment = s:notmuch_view_attachment_default
	endif

	if !exists('g:notmuch_folders_count_threads')
		if exists('g:notmuch_rb_count_threads')
			let g:notmuch_count_threads = g:notmuch_rb_count_threads
		else
			let g:notmuch_folders_count_threads = s:notmuch_folders_count_threads_default
		endif
	endif

	if !exists('g:notmuch_compose_start_insert')
		let g:notmuch_compose_start_insert = s:notmuch_compose_start_insert_default
	endif

	if !exists('g:notmuch_custom_search_maps') && exists('g:notmuch_rb_custom_search_maps')
		let g:notmuch_custom_search_maps = g:notmuch_rb_custom_search_maps
	endif

	if !exists('g:notmuch_custom_show_maps') && exists('g:notmuch_rb_custom_show_maps')
		let g:notmuch_custom_show_maps = g:notmuch_rb_custom_show_maps
	endif

	if exists('g:notmuch_custom_search_maps')
		call extend(g:notmuch_search_maps, g:notmuch_custom_search_maps)
	endif

	if exists('g:notmuch_custom_show_maps')
		call extend(g:notmuch_show_maps, g:notmuch_custom_show_maps)
	endif

	if !exists('g:notmuch_folders')
		if exists('g:notmuch_rb_folders')
			let g:notmuch_folders = g:notmuch_rb_folders
		else
			let g:notmuch_folders = s:notmuch_folders_default
		endif
	endif
endfunction

function! s:NotMuch(...)
	call s:set_defaults()

ruby << EOF
	require 'notmuch'
	require 'rubygems'
	require 'tempfile'
	require 'socket'
	begin
		require 'mail'
	rescue LoadError
	end

	$db_name = nil
	$all_emails = []
	$email = $email_name = $email_address = nil
	$searches = []
	$threads = []
	$messages = []
	$mail_installed = defined?(Mail)

	def get_config_item(item)
		result = ''
		IO.popen(['notmuch', 'config', 'get', item]) { |out|
			result = out.read
		}
		return result.rstrip
	end

	def get_config
		$exclude_tags = get_config_item('search.exclude_tags').split("\n")
		$db_name = get_config_item('database.path')
		$email_name = get_config_item('user.name')
		$email_address = get_config_item('user.primary_email')
		$secondary_email_addresses = get_config_item('user.primary_email')
		$email_name = get_config_item('user.name')
		$email = "%s <%s>" % [$email_name, $email_address]
		other_emails = get_config_item('user.other_email')
		$all_emails = other_emails.split("\n")
		# Add the primary to this too as we use it for checking
		# addresses when doing a reply
		$all_emails.unshift($email_address)
	end

	def vim_puts(s)
		VIM::command("echo '#{s.to_s}'")
	end

	def vim_p(s)
		VIM::command("echo '#{s.inspect}'")
	end

	def author_filter(a)
		# TODO email format, aliases
		a.strip!
		a.gsub!(/[\.@].*/, '')
		a.gsub!(/^ext /, '')
		a.gsub!(/ \(.*\)/, '')
		a
	end

	def get_thread_id
		n = $curbuf.line_number - 1
		return "thread:%s" % $threads[n]
	end

	def get_message
		n = $curbuf.line_number
		return $messages.find { |m| n >= m.start && n <= m.end }
	end

	def get_cur_view
		if $cur_filter
			return "#{$cur_thread} and (#{$cur_filter})"
		else
			return $cur_thread
		end
	end

	def generate_message_id
		t = Time.now
		random_tag = sprintf('%x%x_%x%x%x',
			t.to_i, t.tv_usec,
			$$, Thread.current.object_id.abs, rand(255))
		return "<#{random_tag}@#{Socket.gethostname}.notmuch>"
	end

	def open_compose_helper(lines, cur)
		help_lines = [
			'Notmuch-Help: Type in your message here; to help you use these bindings:',
			'Notmuch-Help:   ,s	- send the message (Notmuch-Help lines will be removed)',
			'Notmuch-Help:   ,q	- abort the message',
			]

		dir = File.expand_path('~/.notmuch/compose')
		FileUtils.mkdir_p(dir)
		Tempfile.open(['nm-', '.mail'], dir) do |f|
			f.puts(help_lines)
			f.puts
			f.puts(lines)

			sig_file = File.expand_path('~/.signature')
			if File.exists?(sig_file)
				f.puts("-- ")
				f.write(File.read(sig_file))
			end

			f.flush

			cur += help_lines.size + 1

			VIM::command("let s:reply_from='%s'" % $email_address)
			VIM::command("call s:new_file_buffer('compose', '#{f.path}')")
			VIM::command("call cursor(#{cur}, 0)")
		end
	end

	def is_our_address(address)
		$all_emails.each do |addy|
			if address.to_s.index(addy) != nil
				return addy
			end
		end
		return nil
	end

	def open_reply(orig)
		reply = orig.reply do |m|
			m.cc = []
			m.to = []
			email_addr = $email_address
			# Use hashes for email addresses so we can eliminate duplicates.
			to = Hash.new
			cc = Hash.new
			if orig[:from]
				orig[:from].each do |o|
					to[o.address] = o
				end
			end
			if orig[:cc]
				orig[:cc].each do |o|
					cc[o.address] = o
				end
			end
			if orig[:to]
				orig[:to].each do |o|
					cc[o.address] = o
				end
			end
			to.each do |e_addr, addr|
				m.to << addr
			end
			cc.each do |e_addr, addr|
				if is_our_address(e_addr)
					email_addr = is_our_address(e_addr)
				else
					m.cc << addr
				end
			end
			m.to = m[:reply_to] if m[:reply_to]
			m.from = "#{$email_name} <#{email_addr}>"
			m.charset = 'utf-8'
		end

		lines = []

		body_lines = []
		if $mail_installed
			addr = Mail::Address.new(orig[:from].value)
			name = addr.name
			name = addr.local + "@" if name.nil? && !addr.local.nil?
		else
			name = orig[:from]
		end
		name = "somebody" if name.nil?

		body_lines << "%s wrote:" % name
		part = orig.find_first_text
		part.convert.each_line do |l|
			body_lines << "> %s" % l.chomp
		end
		body_lines << ""
		body_lines << ""
		body_lines << ""

		reply.body = body_lines.join("\n")

		lines += reply.present.lines.map { |e| e.chomp }
		lines << ""

		cur = lines.count - 1

		open_compose_helper(lines, cur)
	end

	def open_compose()
		lines = []

		lines << "From: #{$email}"
		lines << "To: "
		cur = lines.count

		lines << "Cc: "
		lines << "Bcc: "
		lines << "Subject: "
		lines << ""
		lines << ""
		lines << ""

		open_compose_helper(lines, cur)
	end

	def folders_render()
		$curbuf.render do |b|
			folders = VIM::evaluate('g:notmuch_folders')
			count_threads = VIM::evaluate('g:notmuch_folders_count_threads') == 1
			$searches.clear
			folders.each do |name, search|
				q = $curbuf.query(search)
				$exclude_tags.each { |t|
					q.add_tag_exclude(t)
				}
				$searches << search
				count = count_threads ? q.count_threads : q.count_messages
				b << "%9d %-20s (%s)" % [count, name, search]
			end
		end
	end

	def search_render(search)
		date_fmt = VIM::evaluate('g:notmuch_date_format')
		q = $curbuf.query(search)
		q.sort = Notmuch::SORT_NEWEST_FIRST
		$exclude_tags.each { |t|
			q.add_tag_exclude(t)
		}
		$threads.clear
		t = q.search_threads

		# $render =
		$curbuf.render_staged(t) do |b, items|
			items.each do |e|
				authors = e.authors.to_utf8.split(/[,|]/).map { |a| author_filter(a) }.join(",")
				date = Time.at(e.newest_date).strftime(date_fmt)
				subject = e.messages.first['subject']
				if $mail_installed
					subject = Mail::Field.parse("Subject: " + subject).to_s
				else
					subject = subject.force_encoding('utf-8')
				end
				b << "%-12s %3s %-20.20s | %s (%s)" % [date, e.matched_messages, authors, subject, e.tags]
				$threads << e.thread_id
			end
		end
	end

	def do_tag(filter, tags)
		$curbuf.do_write do |db|
			q = db.query(filter)
			q.search_messages.each do |e|
				e.freeze
				tags.split.each do |t|
					case t
					when /^-(.*)/
						e.remove_tag($1)
					when /^\+(.*)/
						e.add_tag($1)
					when /^([^\+^-].*)/
						e.add_tag($1)
					end
				end
				e.thaw
				e.tags_to_maildir_flags
			end
			q.destroy!
		end
	end

	module DbHelper
		def init(name)
			@name = name
			@db = Notmuch::Database.new($db_name)
			@queries = []
		end

		def query(*args)
			q = @db.query(*args)
			@queries << q
			q
		end

		def close
			@queries.delete_if { |q| ! q.destroy! }
			@db.close
		end

		def reopen
			close if @db
			@db = Notmuch::Database.new($db_name)
		end

		def do_write
			db = Notmuch::Database.new($db_name, :mode => Notmuch::MODE_READ_WRITE)
			begin
				yield db
			ensure
				db.close
			end
		end
	end

	class Message
		attr_accessor :start, :body_start, :end
		attr_reader :message_id, :filename, :mail

		def initialize(msg, mail)
			@message_id = msg.message_id
			@filename = msg.filename
			@mail = mail
			@start = 0
			@end = 0
			mail.import_headers(msg) if not $mail_installed
		end

		def to_s
			"id:%s" % @message_id
		end

		def inspect
			"id:%s, file:%s" % [@message_id, @filename]
		end
	end

	class StagedRender
		def initialize(buffer, enumerable, block)
			@b = buffer
			@enumerable = enumerable
			@block = block
			@last_render = 0

			@b.render { do_next }
		end

		def is_ready?
			@last_render - @b.line_number <= $curwin.height
		end

		def do_next
			items = @enumerable.take($curwin.height * 2)
			return if items.empty?
			@block.call @b, items
			@last_render = @b.count
		end
	end

	class VIM::Buffer
		include DbHelper
		attr :renderer

		def <<(a)
			# work-around for appending blank lines
			append(count(), 'XXX')
			self[count()] = a
		end

		def render_staged(enumerable, &block)
			@renderer = StagedRender.new(self, enumerable, block)
		end

		def render
			old_count = count
			yield self
			(1..old_count).each do
				delete(1)
			end
		end
	end

	class Notmuch::Tags
		def to_s
			to_a.join(" ")
		end
	end

	class Notmuch::Message
		def to_s
			"id:%s" % message_id
		end
	end

	# workaround for bug in vim's ruby
	class Object
		def flush
		end
	end

	module SimpleMessage
		class Header < Array
			def self.parse(string)
				return nil if string.empty?
				return Header.new(string.split(/,\s+/))
			end

			def to_s
				self.join(', ')
			end
		end

		def initialize(string = nil)
			@raw_source = string
			@body = nil
			@headers = {}

			return if not string

			if string =~ /(.*?(\r\n|\n))\2/m
				head, body = $1, $' || '', $2
			else
				head, body = string, ''
			end
			@body = body
		end

		def [](name)
			@headers[name.to_sym]
		end

		def []=(name, value)
			@headers[name.to_sym] = value
		end

		def format_header(value)
			value.to_s.tr('_', '-').gsub(/(\w+)/) { $1.capitalize }
		end

		def to_s
			buffer = ''
			@headers.each do |key, value|
				buffer << "%s: %s\r\n" %
					[format_header(key), value]
			end
			buffer << "\r\n"
			buffer << @body
			buffer
		end

		def body=(value)
			@body = value
		end

		def from
			@headers[:from]
		end

		def decoded
			@body
		end

		def mime_type
			'text/plain'
		end

		def multipart?
			false
		end

		def reply
			r = Mail::Message.new
			r[:from] = self[:to]
			r[:to] = self[:from]
			r[:cc] = self[:cc]
			r[:in_reply_to] = self[:message_id]
			r[:references] = self[:references]
			r
		end

		HEADERS = [ :from, :to, :cc, :references, :in_reply_to, :reply_to, :message_id ]

		def import_headers(m)
			HEADERS.each do |e|
				dashed = format_header(e)
				@headers[e] = Header.parse(m[dashed])
			end
		end
	end

	module Mail

		if not $mail_installed
			puts "WARNING: Install the 'mail' gem, without it support is limited"

			def self.read(filename)
				Message.new(File.open(filename, 'rb') { |f| f.read })
			end

			class Message
				include SimpleMessage
			end
		end

		class Message

			def find_first_text
				return self if not multipart?
				return text_part || html_part
			end

			def convert
				if mime_type != "text/html"
					text = decoded
				else
					IO.popen(VIM::evaluate('exists("g:notmuch_html_converter") ? ' +
							'g:notmuch_html_converter : "elinks --dump"'), "w+") do |pipe|
						pipe.write(decode_body)
						pipe.close_write
						text = pipe.read
					end
				end
				text
			end

			def present
				buffer = ''
				header.fields.each do |f|
					buffer << "%s: %s\r\n" % [f.name, f.to_s]
				end
				buffer << "\r\n"
				buffer << body.to_s
				buffer
			end
		end
	end

	class String
		def to_utf8
			RUBY_VERSION >= "1.9" ? force_encoding('utf-8') : self
		end
	end

	get_config
EOF
	if a:0
		call s:search(join(a:000))
	else
		call s:folders()
	endif
endfunction

command -nargs=* NotMuch call s:NotMuch(<f-args>)

" vim: noexpandtab tabstop=4 shiftwidth=4
