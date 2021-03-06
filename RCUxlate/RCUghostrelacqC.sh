#! /bin/sh
#
# Convert C litmus test to auxiliary-variable form.
# This program generates "ghost" write-release and read-acquire
# instructions rather than anything realistic.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, you can access it online at
# http://www.gnu.org/licenses/gpl-2.0.html.
#
# Copyright (C) IBM Corporation, 2015
# Copyright (C) Alan Stern, 2016
#
# Authors: Paul E. McKenney <paulmck@linux.vnet.ibm.com>
#          Alan Stern <stern@rowland.harvard.edu>

gawk '

########################################################################
#
# Data structures:
#
# aux[proc][line]: Litmus test with RCU statements translated.
# lisa[proc][line]: Input litmus-test statements.
# max_line[nproc]: Number of input lines in lisa[].
# ngp: Number of grace periods across all processes.
# ncs: Number of read-side critical sections across all processes.
# nproc: Number of processes
# rcugp_proc[gp]: Process containing RCU grace period gp.
# rcusync_gp[proc:line] Grace period number of sync in proc at line.
# rcucs_proc[cs]: Process containing critical section cs.
# rcu_lastcs[proc]: Number of most recent critical section in proc.
# rcurl_cs[proc:line]: Critical section number of r[lock] in proc at line.
# rcurul_cs[proc:line]: Critical section number of r[unlock] in proc at line.
# rcunext[proc]: Level of critical section nesting.


########################################################################
#
# Litmus-test variables and registers:
#
# gpstartGG: Has grace period GG started yet?  (GG count is one-based.)
# csendNN: Has critical section NN ended yet?  (NN count is one-based.)
#
# r5GGNN: Holds gpstartGG read by critical section NN.
# r6NNGG: Holds csendNN read by grace period GG.


########################################################################
#
# Emit a preamble
#
function emit_preamble(proc_num, line_in, line,  cs_num, g) {
	cs_num = rcurl_cs[proc_num ":" line_in];
	aux[proc_num ":" line++] = "/* preamble #" cs_num " */";
	for (g = 1; g <= ngp; ++g) {
		# Do not check grace periods in the same process
		if (rcugp_proc[g] == proc_num)
			continue;
		aux[proc_num ":" line++] = sprintf("r5%02d%02d = smp_load_ghostacq(gpstart%02d);", g, cs_num, g);
	}
	aux[proc_num ":" line++] = "/* end preamble #" cs_num " */";
	return line;
}

########################################################################
#
# Emit a postamble
#
function emit_postamble(proc_num, line_in, line,  cs_num) {
	cs_num = rcurul_cs[proc_num ":" line_in];
	aux[proc_num ":" line++] = "/* postamble #" cs_num " */";
	aux[proc_num ":" line++] = sprintf("smp_store_ghostrel(csend%02d, 1);", cs_num);
	aux[proc_num ":" line++] = "/* end postamble #" cs_num " */";
	return line;
}

########################################################################
#
# Emit an RCU grace period.
#
function emit_sync(proc_num, line_in, line,  gp_num, i) {
	gp_num = rcusync_gp[proc_num ":" line_in]
	aux[proc_num ":" line++] = "/* GP #" gp_num " */";
	aux[proc_num ":" line++] = sprintf("smp_store_ghostrel(gpstart%02d, 1);", gp_num);
	aux[proc_num ":" line++] = "smp_gbmb();";
	for (i = 1; i <= ncs; ++i) {
		# Do not check critical sections in the same process
		if (rcucs_proc[i] == proc_num)
			continue;
		aux[proc_num ":" line++] = sprintf("r6%02d%02d = smp_load_ghostacq(csend%02d);", i, gp_num, i);
	}
	aux[proc_num ":" line++] = "/* end GP #" gp_num " */";
	return line;
}

########################################################################
#
# Determine whether the specified line of the specified process needs
# checks against any of the grace periods, and cause the litmus-test
# code for the checks to be inserted into the aux[][] array as needed.
#
function do_gp_checks(proc_num, line_in, line_out,  stmt) {
	stmt = lisa[proc_num ":" line_in];
	if (stmt == "rcu_read_lock();")
		line_out = emit_preamble(proc_num, line_in, line_out);
	else if (stmt == "rcu_read_unlock();")
		line_out = emit_postamble(proc_num, line_in, line_out);
	else if (stmt == "synchronize_rcu();")
		line_out = emit_sync(proc_num, line_in, line_out);
	else
		aux[proc_num ":" line_out++] = stmt;
	return line_out;
}

########################################################################
#
# Output the "exists" clause.
#
function output_exists_clause(g, i, pg, pi, k) {
	printf "%s\n", exists;
	k = 0;

	# For each grace-period/critical-section pair:
	for (g = 1; g <= ngp; ++g) {
		pg = rcugp_proc[g];
		for (i = 1; i <= ncs; ++i) {
			pi = rcucs_proc[i];

			# If they are not in the same process...
			if (pg == pi)
				continue;
			# Output the combined variable check.
			if (k == 2) {
				printf("\n");
				k = 0;
			}
			printf(" /\\ (%d:r5%02d%02d=1 \\/ %d:r6%02d%02d=1)",
					pi, g, i, pg, i, g);
			++k;
		}
	}
	print " )\n";
}

########################################################################
#
# Start of patternist code.

# Kill blank lines
/^[ 	]*$/ {
	next;
}

# Kill curly braces, but only in code
incode == 1 && /^[ 	]*[{}]$/ {
	next;
}

# Header line
NR == 1 {
	if ($1 != "C") {
		print "Need C file!";
		exit;
	}
	print $1, $2 "-Auxiliary";
	inpreamble = 1;
	next;
}

# String and comments.
inpreamble == 1 {
	if ($1 ~ /"/) {
		print;
	}
	if ($0 ~ /{/) {
		print;
		if ($0 != "{") {
			print "Line " NR ": Single { to begin initialization!";
			exit;
		}
		inpreamble = 0;
		ininit = 1;
	}
	next;
}

# Initialization statements.
ininit == 1 {
	if ($0 ~ /}/) {
		if ($0 != "}") {
			print "Line " NR ": Single } to end initialization!";
			exit;
		}
		ininit = 0;
		incode = 1;
		line = 1;
		nproc = 0;
		ngp = 0;
	}
	print;
	next;
}

# The "exists" statement at the end.  Handled first due to terminal laziness.
incode == 1 && $1 ~ /^exists/ {
	incode = 0;
	inexists = 1;
	exists = $0;
	gsub(/exists */, "exists (", exists);
	next;
}

# Process header
incode == 1 && $0 ~ /^P/ {
	header[nproc] = $0;
	procname = "P" nproc "(";
	hdrname = substr($0, 1, length(procname));
	if (procname != hdrname) {
		print "Line " NR ": Expected " procname ") header!";
		exit;
	}
	nproc++;
	next;
}

# The statements of the processes.
incode == 1 {
	i = nproc - 1;
	gsub(/^[ 	]*/, "");
	gsub(/[ 	]*$/, "");
	cur_line[i] = $0;
	if (cur_line[i] == "")
		next;
	max_line[i]++;

	if (cur_line[i] == "synchronize_rcu();") {
		if (rcunest[i] + 0 != 0) {
			# Force C syntax error
			cur_line[i] = "synchronize_rcu(@@@Deadlock);";
		} else {
			ngp++;
			rcugp_proc[ngp] = i;
			rcusync_gp[i ":" max_line[i]] = ngp;
		}
	}
	if (cur_line[i] == "rcu_read_lock();") {
		if (rcunest[i] + 0 == 0) {
			ncs++;
			rcucs_proc[ncs] = i;
			rcu_lastcs[i] = ncs;
			rcurl_cs[i ":" max_line[i]] = ncs;
		} else {
			cur_line[i] = "/* nested " cur_line[i] " */";
		}
		rcunest[i]++;
	} else if (cur_line[i] == "rcu_read_unlock();") {
		if (rcunest[i] == 1)
			rcurul_cs[i ":" max_line[i]] = rcu_lastcs[i];
		else
			cur_line[i] = "/* nested " cur_line[i] " */";
		rcunest[i]--;
	}
	lisa[i ":" max_line[i]] = cur_line[i];
	line++;
	next;
}

# In case we have a multi-line "exists" statement, pull it all together.
inexists == 1 {
	exists = exists " " $0;
}

# Translate and output!
END {
	# Do the translation from lisa[] to aux[].
	aux_max_line = 1;
	gp_num = 1;
	for (proc_num = 0; proc_num <= nproc; proc_num++) {
		line_out = 1;
		for (line_in = 1; line_in <= max_line[proc_num]; line_in++) {
			line_out = do_gp_checks(proc_num, line_in, line_out);
			if (line_out > aux_max_line)
				aux_max_line = line_out;
		}
	}
	--aux_max_line;

	# Output the code.
	for (proc_num = 0; proc_num < nproc; proc_num++) {
		sub(")", "", header[proc_num]);
		printf "%s", header[proc_num]; # need additional GP vars!!!

		# For each grace-period:
		for (g = 1; g <= ngp; ++g)
			printf(", int *gpstart%02d", g);
		# For critical-section:
		for (i = 1; i <= ncs; ++i)
			printf(", int *csend%02d", i);
		printf(")\n");
		print "{";
		for (line_out = 1; line_out <= aux_max_line; line_out++) {
			stmt = aux[proc_num ":" line_out];
			if (stmt == "")
				continue;
			printf "\t%s\n", stmt;
		}
		print "}";
	}

	# exists clause.
	output_exists_clause();
}
'
